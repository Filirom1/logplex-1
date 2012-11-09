%% Copyright (c) 2010 Jacob Vorreuter <jacob.vorreuter@gmail.com>
%% 
%% Permission is hereby granted, free of charge, to any person
%% obtaining a copy of this software and associated documentation
%% files (the "Software"), to deal in the Software without
%% restriction, including without limitation the rights to use,
%% copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the
%% Software is furnished to do so, subject to the following
%% conditions:
%% 
%% The above copyright notice and this permission notice shall be
%% included in all copies or substantial portions of the Software.
%% 
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
%% EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
%% OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
%% NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
%% HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
%% WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
%% OTHER DEALINGS IN THE SOFTWARE.
-module(logplex_app).
-behaviour(application).

-define(APP, logplex).


%% Application callbacks
-export([start/2, start_phase/3, stop/1]).

-export([logplex_work_queue_args/0
         ,nsync_opts/0
         ,config/0
         ,config/1
         ,config/2
         ,start/0
         ,a_start/2
        ]).

-include("logplex.hrl").
-include("logplex_logging.hrl").

%%%===================================================================
%%% Convenience Functions
%%%===================================================================

start() ->
    a_start(?APP, permanent).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    ?INFO("at=start", []),
    cache_os_envvars(),
    set_cookie(),
    read_git_branch(),
    read_availability_zone(),
    boot_pagerduty(),
    setup_redgrid_vals(),
    application:start(nsync),
    logplex_sup:start_link().

stop(_State) ->
    ?INFO("at=stop", []),
    ok.

start_phase(listen, normal, _Args) ->
    {ok, _} = supervisor:start_child(logplex_sup,
                                     logplex_api:child_spec()),
    {ok, _} = supervisor:start_child(logplex_sup,
                                     logplex_syslog_sup:child_spec()),
    {ok, _} = supervisor:start_child(logplex_sup,
                                     logplex_logs_rest:child_spec()),
    ok.

cache_os_envvars() ->
    cache_os_envvars([
                      {cookie, "LOGPLEX_COOKIE", optional}
                     ,{http_port, "PORT", required}
                     ,{auth_key, "LOGPLEX_AUTH_KEY", required}
                     ,{core_userpass, "LOGPLEX_CORE_USERPASS", optional}
                     ,{ion_userpass, "LOGPLEX_ION_USERPASS", optional}
                     ,{heroku_domain, "HEROKU_DOMAIN", required}
                     ,{instance_name, "INSTANCE_NAME", required}
                     ,{local_ip, "LOCAL_IP", required}
                     ,{config_redis_url, "LOGPLEX_CONFIG_REDIS_URL", required}
                     ,{redis_stats_url, "LOGPLEX_STATS_REDIS_URL", optional}
                     ,{shard_urls, "LOGPLEX_SHARD_URLS", optional}
                     ,{pagerduty, "PAGERDUTY", optional}
                     ,{pagerduty_key, "ROUTING_PAGERDUTY_SERVICE_KEY", optional}
                     ,{queue_length, "LOGPLEX_QUEUE_LENGTH", optional}
                     ,{drain_buffer_length, "LOGPLEX_DRAIN_BUFFER_LENGTH", optional}
                     ,{redis_buffer_length, "LOGPLEX_REDIS_BUFFER_LENGTH", optional}
                     ,{read_queue_length, "LOGPLEX_READ_QUEUE_LENGTH", optional}
                     ,{workers, "LOGPLEX_WORKERS", optional}
                     ,{drain_writers, "LOGPLEX_DRAIN_WRITERS", optional}
                     ,{redis_writers, "LOGPLEX_REDIS_WRITERS", optional}
                     ,{readers, "LOGPLEX_READERS", optional}
                     ]),
    ok.

cache_os_envvars([]) ->
    ok;
cache_os_envvars([{Key, OsKey, Required}|Tail]) when is_atom(Key) ->
    case os:getenv(OsKey) of
        false when Required == true ->
            config(Key);
        false ->
            ok;    
        OsVal ->
            set_config(Key, OsVal)
    end,
    cache_os_envvars(Tail).

set_config(KeyS, Value) when is_list(KeyS) ->
    set_config(list_to_atom(KeyS), Value);
set_config(Key, Value) when is_atom(Key) ->
    application:set_env(?APP, Key, Value).

config() ->
    application:get_all_env(logplex).

config(Key) when is_atom(Key) ->
    case application:get_env(?APP, Key) of
        undefined -> erlang:error({missing_config, Key});
        {ok, Val} -> Val
    end.

config(Key, Default) ->
    case application:get_env(?APP, Key) of
        undefined -> Default;
        {ok, Val} -> Val
    end.

set_cookie() ->
    case config(cookie) of
        "" -> ok;
        Cookie -> erlang:set_cookie(node(), list_to_atom(Cookie))
    end.

read_git_branch() ->
    GitOutput = hd(string:tokens(os:cmd("git status"), "\n")),
    case re:run(GitOutput, "\# On branch (\\S+)", [{capture, all_but_first, list}]) of
        {match,[Branch]} ->
            application:set_env(logplex, git_branch, Branch);
        _ ->
            ok
    end.

read_availability_zone() ->
    Url = "http://169.254.169.254/latest/meta-data/placement/availability-zone",
    case httpc:request(get, {Url, []}, [{timeout, 2000}, {connect_timeout, 1000}], []) of
        {ok,{{_,200,_}, _Headers, Zone}} ->
            application:set_env(logplex, availability_zone, Zone);
        _ ->
            ok
    end.

boot_pagerduty() ->
    case config(heroku_domain) of
        "heroku.com" ->
            case config(pagerduty) of
                "0" -> ok;
                _ ->
                    ok = application:load(pagerduty),
                    application:set_env(pagerduty, service_key, config(pagerduty_key)),
                    ok = application:start(pagerduty, temporary),
                    ok = error_logger:add_report_handler(logplex_report_handler)
            end;
        _ ->
            ok
    end.

setup_redgrid_vals() ->
    application:load(redgrid),
    application:set_env(redgrid, local_ip, config(local_ip)),
    application:set_env(redgrid, redis_url, config(redis_stats_url)),
    application:set_env(redgrid, domain, config(heroku_domain)),
    ok.

logplex_work_queue_args() ->
    MaxLength = logplex_utils:to_int(config(queue_length)),
    NumWorkers = logplex_utils:to_int(config(workers)),
    [{name, "logplex_work_queue"},
     {max_length, MaxLength},
     {num_workers, NumWorkers},
     {worker_sup, logplex_worker_sup},
     {worker_args, []}].

nsync_opts() ->
    RedisUrl = config(config_redis_url),
    RedisOpts = logplex_utils:parse_redis_url(RedisUrl),
    Ip = case proplists:get_value(ip, RedisOpts) of
        {_,_,_,_}=L -> string:join([integer_to_list(I) || I <- tuple_to_list(L)], ".");
        Other -> Other
    end,
    RedisOpts1 = proplists:delete(ip, RedisOpts),
    RedisOpts2 = [{host, Ip} | RedisOpts1],
    [{callback, {nsync_callback, handle, []}} | RedisOpts2].

a_start(App, Type) ->
    start_ok(App, Type, application:start(App, Type)).

start_ok(_App, _Type, ok) -> ok;
start_ok(_App, _Type, {error, {already_started, _App}}) -> ok;
start_ok(App, Type, {error, {not_started, Dep}}) ->
    ok = a_start(Dep, Type),
    a_start(App, Type);
start_ok(App, _Type, {error, Reason}) ->
    erlang:error({app_start_failed, App, Reason}).
