-module(logplex_report_email_handler).
-behaviour(gen_event).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2, code_change/3]).

%%%----------------------------------------------------------------------
%%% Callback functions from gen_event
%%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, State}          |
%%          Other
%% @hidden
%%----------------------------------------------------------------------
init(_) ->
    gen_smtp_server:start(smtp_server, []),
    {ok, undefined}.

%%----------------------------------------------------------------------
%% Func: handle_event/2
%% Returns: {ok, State}                                |
%%          {swap_handler, Args1, State1, Mod2, Args2} |
%%          remove_handler
%% @hidden
%%----------------------------------------------------------------------
handle_event({error, _Gleader, {_Pid, Format, Data}}, State) ->
    send_email_alert(io_lib:format("~p" ++ Format, [instance_name()|Data])),    
    {ok, State};

handle_event({error_report, _Gleader, {_Pid, std_error, Report}}, State) ->
    send_email_alert(io_lib:format("~p: ~p", [instance_name()|Report])),    
    {ok, State};

handle_event({error_report, _Gleader, {_Pid, Type, Report}}, State) ->
    send_email_alert(io_lib:format("~p [~p]: ~p", [instance_name(), Type, Report])),    
    {ok, State};

handle_event(_, State) ->
    {ok, State}.

%%----------------------------------------------------------------------
%% Func: handle_call/2
%% Returns: {ok, Reply, State}                                |
%%          {swap_handler, Reply, Args1, State1, Mod2, Args2} |
%%          {remove_handler, Reply}
%% @hidden
%%----------------------------------------------------------------------
handle_call(_Request, State) ->
    {ok, ok, State}.

%%----------------------------------------------------------------------
%% Func: handle_info/2
%% Returns: {ok, State}
%% @hidden
%%----------------------------------------------------------------------
handle_info(_Info, State) ->
    {ok, State}.

%%----------------------------------------------------------------------
%% Func: terminate/2
%% Purpose: Shutdown the server
%% Returns: any
%% @hidden
%%----------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%% @hidden
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------
instance_name() ->
    os:getenv("INSTANCE_NAME").

send_email_alert(Body) ->
    gen_smtp_client:send({"routing@heroku.com", ["routing@heroku.com"],
                          io_lib:format("Subject: Logplex Alert\r\nFrom: Logplex \r\nTo: Routing \r\n\r\n~p: ", [Body])},
                         [{relay, "localhost"}, {port, logplex_app:config(email_port, 25)}, {ssl, true}]).
