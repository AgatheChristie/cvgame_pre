-module(cvgame_pre_prv).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, cvgame_pre).
-define(DEPS, [app_discovery]).

-include_lib("kernel/include/file.hrl").

%% ===================================================================
%% Public API
%% ===================================================================
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Provider = providers:create([
            {name, ?PROVIDER},            % The 'user friendly' name of the task
            {module, ?MODULE},            % The module implementation of the task
            {bare, true},                 % The task can be run by the user, always true
            {deps, ?DEPS},                % The list of dependencies
            {example, "rebar3 cvgame_pre"}, % How to use the plugin
            {opts, []},                   % list of options understood by the plugin
            {short_desc, "A rebar plugin"},
            {desc, "A rebar plugin"}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.



-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
    erlang:statistics(wall_clock),
    AppList = rebar_state:project_apps(State),
    GameServerApp = lists:keyfind(<<"game_server">>, 2, AppList),
    EbinDir = rebar_app_info:ebin_dir(GameServerApp),
    code:add_path(EbinDir),
    {ok, Files} = file:list_dir(EbinDir),
    {OldModules, OldAModules, LastMTime} = get_player_module_info(),
    {PlayerModules, ActivityModules, IsChanged} = find_modules(Files, LastMTime, OldModules, OldAModules),
    case IsChanged of
        true ->
            generate_player_module_(PlayerModules, ActivityModules);
        false ->
            ok
    end,
    {_, T} = erlang:statistics(wall_clock),
    io:format("generate player_module_.beam need time ~p ms,~n", [T]),
    generate_compile_time_(),
    {_, T1} = erlang:statistics(wall_clock),
    io:format("generate compile_time_.beam need time ~p ms,~n", [T1]),
    {ok, State}.

get_player_module_info() ->
    case file:read_file_info("_build/default/lib/game_server/ebin/player_module_.beam") of
        {ok, FileInfo} ->
            {player_module_:get_player_modules(), player_module_:get_activity_modules(),
                FileInfo#file_info.mtime};
        {error, _Reason} ->
            {[], [], 0}
    end.

-spec format_error(any()) ->  iolist().
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

find_modules(Files, LastMTime, Modules, ActivityModules) ->
    FilesToCheck = lists:filtermap(fun(F) -> need_check(F, LastMTime) end, Files),
    code:atomic_load(FilesToCheck),
    lists:foldl(
        fun(M, {TmpModules, TmpAModules, TmpIsChanged}) ->
            {TmpModules1, TmpIsChanged1} = check_export({add_player_listener, 0}, M, TmpModules, TmpIsChanged),
            {TmpAModules1, TmpIsChanged2} = check_export({add_activity_listener, 0}, M, TmpAModules, TmpIsChanged1),
            {TmpModules1, TmpAModules1, TmpIsChanged2}
        end, {Modules, ActivityModules, false}, FilesToCheck).

check_export(Export, M, TmpModules, TmpIsChanged) ->
    case lists:member(Export, M:module_info(exports)) of
        true ->
            case lists:member(M, TmpModules) of
                true -> {TmpModules, TmpIsChanged};
                false -> {[M | TmpModules], true}
            end;
        false ->
            case lists:member(M, TmpModules) of
                true ->
                    {lists:delete(M, TmpModules), true};
                false ->
                    {TmpModules, TmpIsChanged}
            end
    end.

need_check(File, LastMTime) ->
    Dir = "_build/default/lib/game_server/ebin/",
    case string:split(File, ".") of
        [H, "beam"] ->
            case string:split(H, "_", trailing) of
                [_, "data"] ->
                    false;
                [_, "rpc"] ->
                    false;
                [_, "server"] ->
                    false;
                [_, "utils"] ->
                    false;
                [_, "mgr"] ->
                    false;
                _ ->
                    {ok, #file_info{mtime = MTime}} = file:read_file_info(Dir ++ File),
                    case MTime > LastMTime of
                        true -> {true, list_to_atom(H)};
                        false -> false
                    end
            end;
        _ ->
            false
    end.

%% @doc 生成 player_module_.beam 文件，
%% 这个模块有个 导出函数 get_player_modules/0, 获得需要监听事件的玩家模块
generate_player_module_(Modules, ActivityModules) ->
    Forms = forms(Modules, ActivityModules),
    OutFile = "_build/default/lib/game_server/ebin/player_module_.beam",
    form_to_file(Forms, OutFile).

generate_compile_time_() ->
    B = << <<"last_compile_time() -> ">>/binary,
        (integer_to_binary(date_utils:unixtime()))/binary, <<".">>/binary >>,
    {ok, Func} = parse_func_string(binary_to_list(B)),
    Forms = [
        {attribute, 2, module, compile_time_},
        {attribute, 3, export, [{last_compile_time, 0}]},
        Func
    ],
    OutFile = "_build/default/lib/game_server/ebin/compile_time_.beam",
    form_to_file(Forms, OutFile).


%% @doc 生成 player_module_ 模块需要的 forms.
forms(Modules, ActivityModules) ->
    B = << <<"get_player_modules() -> ">>/binary, (common_utils:term_to_binary(Modules))/binary,
        <<".">>/binary >>,
    {ok, PlayerForm} = parse_func_string(binary_to_list(B)),
    AB = << <<"get_activity_modules() -> ">>/binary, (common_utils:term_to_binary(ActivityModules))/binary,
        <<".">>/binary >>,
    {ok, ActivityForm} = parse_func_string(binary_to_list(AB)),
    [
        {attribute, 2, module, player_module_},
        {attribute, 3, export, [{get_player_modules, 0}]},
        {attribute, 3, export, [{get_activity_modules, 0}]},
        PlayerForm,
        ActivityForm
    ].

%% @doc 根据函数的对应的 字符串 生成出 function 需要的 form
parse_func_string(Func) ->
    case erl_scan:string(Func) of
        {ok, Toks, _} ->
            case erl_parse:parse_form(Toks) of
                {ok, _Form} = Res ->
                    Res;
                _Err ->
                    {error, parse_error}
            end;
        _Err ->
            {error, parse_error}
    end.

%% @doc 根据 forms 生成 beam 数据，并把数据写到 player_module_.beam 文件里面
form_to_file(Forms, OutFile) ->
    case compile:forms(Forms) of
        {ok, _Module, Bin} ->
            file:write_file(OutFile, Bin);
        Err ->
            io:format("gen ~p error ~p,~n", [OutFile, Err]),
            Err
    end.
