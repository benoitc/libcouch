% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_server_sup).
-behaviour(supervisor).


-export([start_link/1,stop/0, couch_config_start_link_wrapper/2,
        restart_core_server/0, config_change/2]).

-include("couch_db.hrl").

%% supervisor callbacks
-export([init/1]).

start_link(IniFiles) ->
    case whereis(couch_server_sup) of
    undefined ->
        start_server(IniFiles);
    _Else ->
        {error, already_started}
    end.

restart_core_server() ->
    init:restart().

couch_config_start_link_wrapper(IniFiles, FirstConfigPid) ->
    case is_process_alive(FirstConfigPid) of
        true ->
            link(FirstConfigPid),
            {ok, FirstConfigPid};
        false -> couch_config:start_link(IniFiles)
    end.

start_server(IniFiles) ->
    case init:get_argument(pidfile) of
    {ok, [PidFile]} ->
        case file:write_file(PidFile, os:getpid()) of
        ok -> ok;
        Error -> io:format("Failed to write PID file ~s, error: ~p", [PidFile, Error])
        end;
    _ -> ok
    end,

    {ok, ConfigPid} = couch_config:start_link(IniFiles),

    LogLevel = couch_config:get("log", "level", "info"),
    % announce startup

    io:format("couch core ~s is starting ~n", [couch:version()]),
    io:format("~s ~s (LogLevel=~s) is starting.~n", [
            couch_config:get("vendor", "name", "rcouch"),
            couch_config:get("vendor", "version", "0.0"),
            LogLevel
    ]),
    case LogLevel of
    "debug" ->
        io:format("configuration settings ~p:~n", [IniFiles]),
        [io:format("  [~s] ~s=~p~n", [Module, Variable, Value])
            || {{Module, Variable}, Value} <- couch_config:all()];
    _ -> ok
    end,

    BaseChildSpecs =
    {{one_for_all, 10, 3600},
        [{couch_config,
            {couch_server_sup, couch_config_start_link_wrapper, [IniFiles, ConfigPid]},
            permanent,
            brutal_kill,
            worker,
            [couch_config]},
        {couch_primary_services,
            {couch_primary_sup, start_link, []},
            permanent,
            infinity,
            supervisor,
            [couch_primary_sup]},
        {couch_secondary_services,
            {couch_secondary_sup, start_link, []},
            permanent,
            infinity,
            supervisor,
            [couch_secondary_sup]}
        ]},

    % ensure these applications are running
    application:start(ibrowse),
    application:start(crypto),

    {ok, Pid} = supervisor:start_link(
        {local, couch_server_sup}, couch_server_sup, BaseChildSpecs),

    % launch the icu bridge
    % just restart if one of the config settings change.
    couch_config:register(fun ?MODULE:config_change/2, Pid),

    unlink(ConfigPid),

    {ok, Pid}.

stop() ->
    catch exit(whereis(couch_server_sup), normal).

config_change("daemons", _) ->
    supervisor:terminate_child(couch_server_sup, couch_secondary_services),
    supervisor:restart_child(couch_server_sup,
                             couch_secondary_services);
config_change("stat", "rate") ->
    NewRate = integer_to_list(
            couch_config:get_value("stats", "rate", "1000")
    ),
    couch_stats_aggregator:set_rate(NewRate);
config_change("stats", "samples") ->
    SampleStr = couch_config:get("stats", "samples", "[0]"),
    {ok, Samples} = couch_util:parse_term(SampleStr),
    couch_stats_aggregator:set_samples(Samples).


init(ChildSpecs) ->
    {ok, ChildSpecs}.
