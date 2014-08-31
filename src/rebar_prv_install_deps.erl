%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% -------------------------------------------------------------------
%%
%% rebar: Erlang Build Tools
%%
%% Copyright (c) 2009 Dave Smith (dizzyd@dizzyd.com)
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -------------------------------------------------------------------
-module(rebar_prv_install_deps).

-behaviour(rebar_provider).

-export([init/1,
         do/1]).

-include("rebar.hrl").

-export([setup_env/1]).

%% for internal use only
-export([get_deps_dir/1]).
-export([get_deps_dir/2]).

-define(PROVIDER, install_deps).
-define(DEPS, [app_discovery]).

-type src_dep() :: {atom(), string(), {atom(), string(), string()}}.
-type binary_dep() :: {atom(), binary()} | atom().

-type dep() :: src_dep() | binary_dep().

%% ===================================================================
%% Public API
%% ===================================================================

-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    State1 = rebar_state:add_provider(State, #provider{name = ?PROVIDER,
                                                       provider_impl = ?MODULE,
                                                       bare = false,
                                                       deps = ?DEPS,
                                                       example = "rebar deps",
                                                       short_desc = "Install dependencies",
                                                       desc = info("Install dependencies"),
                                                       opts = []}),
    {ok, State1}.

-spec do(rebar_state:t()) -> {ok, rebar_state:t()}.
do(State) ->
    case rebar_state:get(State, locks, []) of
        [] ->
            handle_deps(State, rebar_state:get(State, deps, []));
        _Locks ->
            {ok, State}
    end.

%% set REBAR_DEPS_DIR and ERL_LIBS environment variables
setup_env(State) ->
    DepsDir = get_deps_dir(State),
    %% include rebar's DepsDir in ERL_LIBS
    Separator = case os:type() of
                    {win32, nt} ->
                        ";";
                    _ ->
                        ":"
                end,
    ERL_LIBS = case os:getenv("ERL_LIBS") of
                   false ->
                       {"ERL_LIBS", DepsDir};
                   PrevValue ->
                       {"ERL_LIBS", DepsDir ++ Separator ++ PrevValue}
               end,
    [{"REBAR_DEPS_DIR", DepsDir}, ERL_LIBS].


-spec get_deps_dir(rebar_state:t()) -> file:filename_all().
get_deps_dir(State) ->
    BaseDir = rebar_state:get(State, base_dir, ""),
    get_deps_dir(BaseDir, "deps").

-spec get_deps_dir(file:filename_all(), rebar_state:t()) -> file:filename_all().
get_deps_dir(DepsDir, App) ->
    filename:join(DepsDir, App).

%% ===================================================================
%% Internal functions
%% ===================================================================

handle_deps(State, []) ->
    {ok, State};
handle_deps(State, Deps) ->
    %% Read in package index and dep graph
    {Packages, Graph} = rebar_packages:get_packages(State),
    ProjectApps = rebar_state:project_apps(State),

    %% Split source deps form binary deps, needed to keep backwards compatibility
    DepsDir = get_deps_dir(State),
    {SrcDeps, BinaryDeps} = parse_deps(DepsDir, Deps),
    State1 = rebar_state:src_deps(rebar_state:binary_deps(State, BinaryDeps),
                                  lists:ukeysort(2, SrcDeps)),

    %% Fetch transitive src deps
    State2 = update_src_deps(State1),
    Solved = case rebar_state:binary_deps(State2) of
                 [] -> %% No binary deps
                     [];
                 BinaryDeps1 ->
                     %% Find binary deps needed
                     {ok, S} = rlx_depsolver:solve(Graph, BinaryDeps1),

                     %% Create app_info record for each binary dep
                     lists:map(fun({Name, Vsn}) ->
                                       AppInfo = package_to_app(DepsDir
                                                               ,Packages
                                                               ,Name
                                                               ,Vsn),
                                       ok = maybe_fetch(AppInfo),
                                       AppInfo
                               end, S)
             end,

    FinalDeps = ProjectApps ++ rebar_state:src_deps(State2) ++ Solved,
    %% Sort all apps to build order
    {ok, Sort} = rebar_topo:sort_apps(FinalDeps),
    {ok, rebar_state:project_apps(State2, Sort)}.

-spec package_to_app(file:name(), dict:dict(), binary(), binary()) -> rebar_app_info:t().
package_to_app(DepsDir, Packages, Name, Vsn) ->
    FmtVsn = ec_cnv:to_binary(rlx_depsolver:format_version(Vsn)),

    {ok, P} = dict:find({Name, FmtVsn}, Packages),
    PkgDeps = proplists:get_value(<<"deps">>, P),
    Link = proplists:get_value(<<"link">>, P),

    {ok, AppInfo} = rebar_app_info:new(Name, FmtVsn),
    AppInfo1 = rebar_app_info:deps(AppInfo, PkgDeps),
    AppInfo2 =
        rebar_app_info:dir(AppInfo1, get_deps_dir(DepsDir, <<Name/binary, "-", FmtVsn/binary>>)),
    rebar_app_info:source(AppInfo2, {Name, FmtVsn, Link}).

-spec update_src_deps(rebar_state:t()) -> rebat_state:t().
update_src_deps(State) ->
    SrcDeps = rebar_state:src_deps(State),
    DepsDir = get_deps_dir(State),
    case lists:foldl(fun(AppInfo, {SrcDepsAcc, BinaryDepsAcc}) ->
                             ok = maybe_fetch(AppInfo),
                             {AppInfo1, NewSrcDeps, NewBinaryDeps} = handle_dep(DepsDir, AppInfo),
                             {lists:ukeymerge(2, lists:ukeysort(2, [AppInfo1 | SrcDepsAcc]), lists:ukeysort(2, NewSrcDeps)), NewBinaryDeps++BinaryDepsAcc}
                     end, {[], rebar_state:binary_deps(State)}, SrcDeps) of
        {NewSrcDeps, NewBinaryDeps} when length(SrcDeps) =:= length(NewSrcDeps) ->
            rebar_state:src_deps(rebar_state:binary_deps(State, NewBinaryDeps), NewSrcDeps);
        {NewSrcDeps, NewBinaryDeps} ->
            State1 = rebar_state:src_deps(rebar_state:binary_deps(State, NewBinaryDeps), NewSrcDeps),
            update_src_deps(State1)
    end.

-spec handle_dep(binary(), rebar_state:t()) -> {[rebar_app_info:t()], [binary_dep()]}.
handle_dep(DepsDir, AppInfo) ->
    C = rebar_config:consult(rebar_app_info:dir(AppInfo)),
    S = rebar_state:new(rebar_state:new(), C, rebar_app_info:dir(AppInfo)),
    Deps = rebar_state:get(S, deps, []),
    AppInfo1 = rebar_app_info:deps(AppInfo, rebar_state:deps_names(S)),
    {SrcDeps, BinaryDeps} = parse_deps(DepsDir, Deps),
    {AppInfo1, SrcDeps, BinaryDeps}.

-spec maybe_fetch(rebar_app_info:t()) -> ok.
maybe_fetch(AppInfo) ->
    AppDir = rebar_app_info:dir(AppInfo),
    case filelib:is_dir(AppDir) of
        false ->
            ?INFO("Fetching ~s~n", [rebar_app_info:name(AppInfo)]),
            Source = rebar_app_info:source(AppInfo),
            rebar_fetch:download_source(AppDir, Source);
        true ->
            ok
    end.

-spec parse_deps(binary(), [dep()]) -> {[rebar_app_info:t()], [binary_dep()]}.
parse_deps(DepsDir, Deps) ->
    lists:foldl(fun({Name, Vsn}, {SrcDepsAcc, BinaryDepsAcc}) ->
                        {SrcDepsAcc, [parse_goal(ec_cnv:to_binary(Name)
                                                ,ec_cnv:to_binary(Vsn)) | BinaryDepsAcc]};
                   (Name, {SrcDepsAcc, BinaryDepsAcc}) when is_atom(Name) ->
                        {SrcDepsAcc, [ec_cnv:to_binary(Name) | BinaryDepsAcc]};
                   ({Name, _, Source}, {SrcDepsAcc, BinaryDepsAcc}) ->
                        {ok, Dep} = rebar_app_info:new(Name),
                        Dep1 = rebar_app_info:source(
                                 rebar_app_info:dir(Dep, get_deps_dir(DepsDir, Name)), Source),
                        {[Dep1 | SrcDepsAcc], BinaryDepsAcc}
                end, {[], []}, Deps).

-spec parse_goal(binary(), binary()) -> binary_dep().
parse_goal(Name, Constraint) ->
    case re:run(Constraint, "([^\\d]*)(\\d.*)", [{capture, [1,2], binary}]) of
        {match, [<<>>, Vsn]} ->
            {Name, Vsn};
        {match, [Op, Vsn]} ->
            {Name, Vsn, binary_to_atom(Op, utf8)};
        nomatch ->
            fail
    end.

info(Description) ->
    io_lib:format("~s.~n"
                 "~n"
                 "Valid rebar.config options:~n"
                 "  ~p~n"
                 "  ~p~n"
                 "Valid command line options:~n"
                 "  deps_dir=\"deps\" (override default or rebar.config deps_dir)~n",
                 [
                 Description,
                 {deps_dir, "deps"},
                 {deps,
                  [app_name,
                   {rebar, "1.0.*"},
                   {rebar, ".*",
                    {git, "git://github.com/rebar/rebar.git"}},
                   {rebar, ".*",
                    {git, "git://github.com/rebar/rebar.git", "Rev"}},
                   {rebar, "1.0.*",
                    {git, "git://github.com/rebar/rebar.git", {branch, "master"}}},
                   {rebar, "1.0.0",
                    {git, "git://github.com/rebar/rebar.git", {tag, "1.0.0"}}},
                   {rebar, "",
                    {git, "git://github.com/rebar/rebar.git", {branch, "master"}},
                    [raw]},
                   {app_name, ".*", {hg, "https://www.example.org/url"}},
                   {app_name, ".*", {rsync, "Url"}},
                   {app_name, ".*", {svn, "https://www.example.org/url"}},
                   {app_name, ".*", {svn, "svn://svn.example.org/url"}},
                   {app_name, ".*", {bzr, "https://www.example.org/url", "Rev"}},
                   {app_name, ".*", {fossil, "https://www.example.org/url"}},
                   {app_name, ".*", {fossil, "https://www.example.org/url", "Vsn"}},
                   {app_name, ".*", {p4, "//depot/subdir/app_dir"}}]}
                 ]).
