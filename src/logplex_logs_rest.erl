%% @copyright Geoff Cant
%% @author Geoff Cant <nem@erlang.geek.nz>
%% @version {@vsn}, {@date} {@time}
%% @doc Syslog/HTTP handler for Logplex.
%% @end
-module(logplex_logs_rest).

-include("logplex_logging.hrl").

-export([child_spec/0]).

-export([init/3
         ,rest_init/2
         ,allowed_methods/2
         ,is_authorized/2
         ,known_content_type/2
         ,malformed_request/2
         ,process_post/2
         ,content_types_provided/2
         ,to_response/2
        ]).

%% Healthcheck exports.
-export([handle/2
         ,terminate/2]).

-record(state, {token :: logplex_token:id(),
                name :: logplex_token:name(),
                channel_id :: logplex_channel:id(),
                msgs :: list()}).

child_spec() ->
    cowboy:child_spec(?MODULE, 100,
                      cowboy_tcp_transport,
                      [{port, logplex_app:config(http_log_input_port)}],
                      cowboy_http_protocol,
                      [{dispatch,
                        [{'_', [{[<<"healthcheck">>], ?MODULE, [healthcheck]},
                                {[<<"logs">>], ?MODULE, [logs]}]}]}]).


init(_Transport, Req, [healthcheck]) ->
    {ok, Req, undefined};
init(_Transport, _Req, [logs]) ->
    {upgrade, protocol, cowboy_http_rest}.

%% Healthcheck implementation
handle(Req, State) ->
    {ok, Req2} = cowboy_http_req:reply(200, [], <<"OK">>, Req),
    {ok, Req2, State}.

terminate(_, _) -> ok.

%% Logs cowboy_rest implementation
rest_init(Req, _Opts) ->
    {ok, Req, #state{}}.

allowed_methods(Req, State) ->
    {['POST'], Req, State}.

is_authorized(Req, State) ->
    case cowboy_http_req:header('Authorization', Req) of
        {<<"Basic ", Base64/binary>>, Req2} ->
            case binary:split(base64:decode(Base64), <<":">>) of
                [_User, TokenId = <<"t.", _/binary>>] ->
                    case logplex_token:lookup(TokenId) of
                        undefined ->
                            ?INFO("at=authorization err=unknown_token token=~p", [TokenId]),
                            {{false, <<"Basic realm=Logplex">>}, Req2, State};
                        Token ->
                            Name = logplex_token:name(Token),
                            ChanId = logplex_token:channel_id(Token),
                            {true, Req2,
                             State#state{name=Name,
                                         channel_id=ChanId,
                                         token=logplex_token:id(Token)}}
                    end;
                _Else ->
                    ?INFO("at=authorization err=incorrect_auth_header hdr=~p", [_Else]),
                    {{false, <<"Basic realm=Logplex">>}, Req2, State}
            end;
        {_, Req2} ->
            ?INFO("at=authorization err=missing_auth_header", []),
            {{false, <<"Basic realm=Logplex">>}, Req2, State}
    end.

known_content_type(Req, State) ->
    case cowboy_http_req:header('Content-Type', Req) of
        {<<"application/logplex-1">>, Req2} ->
            {true, Req2, State};
        {_, Req2} ->
            {false, Req2, State}
    end.

malformed_request(Req, State) ->
    {false, Req, State}.

%% XXX - Doesn't get used in current cowboy rest code. #fail
%% content_types_accepted(Req, State) ->
%%     {[{{<<"application">>, <<"x-logplex-1">>, []}, from_logplex},
%%       {{<<"application">>, <<"logplex-1">>, []}, from_logplex}],
%%      Req, State}.
%% from_logplex(Req, State) ->
%%     case parse_logplex_body(Req, State) of
%%         {parsed, Req2, State2} ->
%%             {true, Req2, State2};
%%         {{error, _Reason}, Req2, State2} ->
%%             {false, Req2, State2}
%%     end.

process_post(Req, State = #state{token = Token,
                                 channel_id = ChannelId,
                                 name = Name})
             when is_binary(Token) ->
    try parse_logplex_body(Req, State) of
        {parsed, Req2, State2 = #state{msgs = Msgs}} when is_list(Msgs)->
            logplex_message:process_msgs(Msgs, ChannelId, Token, Name),
            {true, Req2, State2#state{msgs = []}};
        {{error, Reason}, Req2, State2} ->
            ?WARN("at=parse_logplex_body error=~p", [Reason]),
            %% XXX - Log parse failure
            {false, Req2, State2}
    catch
        Class:Error ->
            Stack = erlang:get_stacktrace(),
            ?WARN("at=process_post exception=~p:~p stack=~1000p",
                  [Class, Error, Stack]),
            {false, Req, State}
    end.

parse_logplex_body(Req, State) ->
    {ok, Body, Req2} = cowboy_http_req:body(Req),
    case syslog_parser:parse(Body) of
        {ok, Msgs, _} ->
            case cowboy_http_req:header(<<"Logplex-Msg-Count">>
                                        , Req2, false) of
                {false, Req3} ->
                    {parsed, Req3, State#state{msgs=Msgs}};
                {Val, Req3} ->
                    try
                        Count = list_to_integer(binary_to_list(Val)),
                        Count = length(Msgs),
                        {parsed, Req3, State#state{msgs=Msgs}}
                    catch
                        _:_ ->
                            {{error, msg_count_mismatch}, Req3, State}
                    end
            end;
        {{error, Reason}, _, _} ->
            ?WARN("at=parse_syslog reason=~p body=~1000p",
                  [Reason, Body]),
            {{error, Reason}, Req2, State}
    end.


content_types_provided(Req, State) ->
    {[{{<<"text">>, <<"plain">>, []}, to_response}],
     Req, State}.

to_response(Req, State) ->
    {"OK", Req, State}.
