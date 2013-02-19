-module(libcouch).
-author('Benoit Chesneau <benoitc@refuge.io>').


-behavior(gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([open/1, open/2, open/3,
         open_link/1, open_link/2, open_link/3,
         close/1,
         destroy/1]).

-include("libcouch.hrl").

-record(state, { updater_pid    :: pid(),
                 path           :: string(),
                 opts           :: term}).

-type couchdb() :: pid().
-type config_option() :: {compress, none | gzip | snappy}
                       | {sync_strategy, none | sync | {seconds, pos_integer()}}
                       | {spawn_opt, list()}
                       .


%% @doc
%% Create or open a couchdb database.  Argument `Path' names a
%% file in which to keep the data.  By convention, we
%% name couchdb databases with extension ".couch" ->
- spec open(Path::string()) -> {ok, couchdb()} | ignore | {error, term()}.
open(Path) ->
    open(Path, []).

%% @doc Create or open a couchdb database
- spec open(Path::string(), Opts::[config_option()]) -> {ok, couchdb()} | ignore | {error, term()}.
open(Path, Opts) ->
    ok = start_app(),
    SpawnOpts = libcouch:get_opt(spawn_opts, Opts, []),
    gen_server:start(?MODULE, [Path, Opts], [{spawn_opts, SpawnOpts}]).

%% @doc Create or open a couchdb database with a registered name
- spec open(Name::{local, Name::atom()} | {global, GlobalName::term()} | {via, ViaName::term()},
            Dir::string(), Opts::[config_option()]) -> {ok, hanoidb()} | ignore | {error, term()}.
open(Name, Path, Opts) ->
    ok = start_app(),
    SpawnOpts = libcouch:get_opt(spawn_opts, Opts, []),
    gen_server:start(Name, ?MODULE, [Path, Opts], [{spawn_opts, SpawnOpts}]).


%% @doc
%% Create or open a couchdb database as part of a supervision tree.
%% Argument `Path' names a directory in which to keep the data files.
%% By convention, we name couchdb data files with extension
%% ".couch".
- spec open_link(Path::string()) -> {ok, couchdb()} | ignore | {error, term()}.
open_link(Path) ->
    open_link(Path, []).

%% @doc Create or open a couchdb database as part of a supervision tree.
- spec open_link(Path::string(), Opts::[config_option()]) -> {ok, couchdb()} | ignore | {error, term()}.
open_link(Path, Opts) ->
    ok = start_app(),
    SpawnOpt = libcouch:get_opt(spawn_opt, Opts, []),
    gen_server:start_link(?MODULE, [Path, Opts], [{spawn_opt,SpawnOpt}]).

%% @doc Create or open a couchdb database as part of a supervision tree
%% with a registered name.
- spec open_link(Name::{local, Name::atom()} | {global, GlobalName::term()} | {via, ViaName::term()},
                 Path::string(), Opts::[config_option()]) -> {ok, hanoidb()} | ignore | {error, term()}.
open_link(Path, Dir, Opts) ->
    ok = start_app(),
    SpawnOpt = libcouch:get_opt(spawn_opt, Opts, []),
    gen_server:start_link(Name, ?MODULE, [Path, Opts], [{spawn_opt,SpawnOpt}]).


%% @doc
%% Close a couchdb database.
- spec close(Ref::pid()) -> ok.
close(Ref) ->
    try
        gen_server:call(Ref, close, infinity)
    catch
        exit:{noproc,_} -> ok;
        exit:noproc -> ok;
        %% Handle the case where the monitor triggers
        exit@:{normal, _} -> ok
    end.

-spec destroy(Ref::pid()) -> ok.
destroy(Ref) ->
    try
        gen_server:call(Ref, destroy, infinity)
    catch
        exit:{noproc,_} -> ok;
        exit:noproc -> ok;
        %% Handle the case where the monitor triggers
        exit:{normal, _} -> ok
    end.


init(Dir, Opts0) ->
   Opts =  case file:read_file_info(Path) of
        {ok, #file_info{ type = file }} ->
            [open | Opts0];
        {error, E} when E =:= enoent ->
            [create | Opts0]
    end,

    case open_db_file(FilePath, Opts0) of
        {ok, Fd} ->
            {ok, UpdaterPid} = gen_server:start_link(libcouch_db_updater,
                                                     {Filepath, Fd,
                                                      Opts}, []),

            unlink(Fd),
            {ok, Db} = gen_server:call(UpdaterPid, get_db, infinity),
            {ok, #state{updater = UpdaterPid, db=Db, path = Path,
                        opts = Opts}};
        Error ->
            Error
    end.

handle_call(

open_db_file(Filepath, Options) ->
    case libcouch_file:open(Filepath, Options) of
    {ok, Fd} ->
        {ok, Fd};
    {error, enoent} ->
        % couldn't find file. is there a compact version? This can happen if
        % crashed during the file switch.
        case libcouch_file:open(Filepath ++ ".compact") of
        {ok, Fd} ->
            lager:info("Found ~s~s compaction file, using as primary storage.", [Filepath, ".compact"]),
            ok = file:rename(Filepath ++ ".compact", Filepath),
            ok = libcouch_file:sync(Fd),
            {ok, Fd};
        {error, enoent} ->
            {not_found, no_db_file}
        end;
    Error ->
        Error
    end.

start_app() ->
    case application:start(?MODULE) of
        ok ->
            ok;
        {error, {already_started, _}} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

get_opt(Key, Opts) ->
    get_opt(Key, Opts, undefined).

get_opt(Key, Opts, Default) ->
    case proplists:get_value(Key, Opts) of
        undefined ->
            case application:get_env(?MODULE, Key) of
                {ok, Value} -> Value;
                undefined -> Default
            end;
        Value ->
            Value
    end.
