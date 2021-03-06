-module(els_test_utils).

-export([ all/1
        , all/2
        , end_per_suite/1
        , end_per_testcase/2
        , get_group/1
        , groups/1
        , init_per_suite/1
        , init_per_testcase/2
        , start/1
        , wait_for/2
        ]).

-type config() :: [{atom(), any()}].

-include_lib("common_test/include/ct.hrl").

%%==============================================================================
%% Defines
%%==============================================================================
-define(TEST_APP, <<"code_navigation">>).
-define(HOSTNAME, {127, 0, 0, 1}).
-define(PORT    , 10000).

-spec groups(module()) -> [{atom(), [], [atom()]}].
groups(Module) ->
  [ {tcp,   [], all(Module)}
  , {stdio, [], all(Module)}
  ].

-spec all(module()) -> [atom()].
all(Module) -> all(Module, []).

-spec all(module(), [atom()]) -> [atom()].
all(Module, Functions) ->
  ExcludedFuns = [init_per_suite, end_per_suite, all, module_info | Functions],
  Exports = Module:module_info(exports),
  [F || {F, 1} <- Exports, not lists:member(F, ExcludedFuns)].

-spec init_per_suite(config()) -> config().
init_per_suite(Config) ->
  PrivDir = code:priv_dir(erlang_ls),
  RootPath = filename:join([ list_to_binary(PrivDir)
                           , ?TEST_APP]),
  RootUri = els_uri:uri(RootPath),
  application:load(erlang_ls),
  Priv = ?config(priv_dir, Config),
  application:set_env(erlang_ls, db_dir, Priv),
  SrcConfig = lists:flatten(
                [file_config(RootPath, src, S) || S <- sources()]),
  IncludeConfig = lists:flatten(
                    [file_config(RootPath, include, S) || S <- includes()]),
  lists:append( [ SrcConfig
                , IncludeConfig
                , [ {root_uri, RootUri}
                  , {root_path, RootPath}
                  | Config]
                ]).

-spec end_per_suite(config()) -> ok.
end_per_suite(_Config) ->
  ok.

-spec init_per_testcase(atom(), config()) -> config().
init_per_testcase(_TestCase, Config) ->
  Transport = get_group(Config),
  Started   = start(Transport),
  RootUri   = ?config(root_uri, Config),

  els_client:initialize(RootUri, []),

  %% Ensure modules used in test suites are indexed
  index_modules(),

  [{started, Started} | Config].

-spec end_per_testcase(atom(), config()) -> ok.
end_per_testcase(_TestCase, Config) ->
  [application:stop(App) || App <- ?config(started, Config)],
  ok.

-spec start(stdio | tcp) -> [atom()].
start(stdio) ->
  ClientIo = els_fake_stdio:start(),
  ServerIo = els_fake_stdio:start(),
  els_fake_stdio:connect(ClientIo, ServerIo),
  els_fake_stdio:connect(ServerIo, ClientIo),
  ok = application:set_env(erlang_ls, transport, els_stdio),
  ok = application:set_env(erlang_ls, io_device, ServerIo),
  {ok, Started} = application:ensure_all_started(erlang_ls),
  els_client:start_link(stdio, #{io_device => ClientIo}),
  Started;
start(tcp) ->
  ok = application:set_env(erlang_ls, transport, els_tcp),
  {ok, Started} = application:ensure_all_started(erlang_ls),
  els_client:start_link(tcp, #{host => ?HOSTNAME, port => ?PORT}),
  Started.

-spec wait_for(any(), non_neg_integer()) -> ok.
wait_for(_Message, Timeout) when Timeout =< 0 ->
  timeout;
wait_for(Message, Timeout) ->
  receive Message -> ok
  after 10 -> wait_for(Message, Timeout - 10)
  end.

-spec get_group(config()) -> atom().
get_group(Config) ->
  GroupProperties = ?config(tc_group_properties, Config),
  proplists:get_value(name, GroupProperties).

-spec sources() -> [atom()].
sources() ->
  [ 'diagnostics.new'
  , behaviour_a
  , code_navigation
  , code_navigation_extra
  , code_navigation_types
  , diagnostics
  , diagnostics_behaviour
  , diagnostics_behaviour_impl
  , diagnostics_macros
  , diagnostics_parse_transform
  , diagnostics_parse_transform_usage
  , diagnostics_parse_transform_usage_included
  , elvis_diagnostics
  , format_input
  , my_gen_server
  ].

-spec includes() -> [atom()].
includes() ->
  [ code_navigation
  , diagnostics
  ].

%% @doc Produce the config entries for a file identifier
%%
%%      Given an identifier representing a source or include file,
%%      produce a config containing the respective path, uri and text
%%      to simplify accessing this information from test cases.
-spec file_config(binary(), src | include, atom()) ->
        [{atom(), any()}].
file_config(RootPath, Type, Id) ->
  BinaryId = atom_to_binary(Id, utf8),
  Ext = extension(Type),
  Dir = directory(Type),
  Path = filename:join([RootPath, Dir, <<BinaryId/binary, Ext/binary>>]),
  Uri = els_uri:uri(Path),
  {ok, Text} = file:read_file(Path),
  ConfigId = config_id(Id, Type),
  [ {atoms_append(ConfigId, '_path'), Path}
  , {atoms_append(ConfigId, '_uri'), Uri}
  , {atoms_append(ConfigId, '_text'), Text}
  ].

-spec config_id(atom(), src | include) -> atom().
config_id(Id, src) -> Id;
config_id(Id, include) -> list_to_atom(atom_to_list(Id) ++ "_h").

-spec directory(src | include) -> binary().
directory(Atom) ->
  atom_to_binary(Atom, utf8).

-spec extension(src | include) -> binary().
extension(src) ->
  <<".erl">>;
extension(include) ->
  <<".hrl">>.

-spec atoms_append(atom(), atom()) -> atom().
atoms_append(Atom1, Atom2) ->
  Bin1 = atom_to_binary(Atom1, utf8),
  Bin2 = atom_to_binary(Atom2, utf8),
  binary_to_atom(<<Bin1/binary, Bin2/binary>>, utf8).

index_modules() ->
  [els_indexer:find_and_index_file(Module) || Module <- modules_to_index()].

modules_to_index() ->
  [ "behaviour_a"
  , "code_navigation"
  , "code_navigation.hrl"
  , "code_navigation_extra"
  , "code_navigation_types"
  , "diagnostics.hrl"
  , "diagnostics_behaviour"
  , "diagnostics_behaviour_impl"
  , "my_gen_server"
  ].
