%%% ---------------------------------------------------------------------------
%%% @doc
%%%
%%% This module fetches information from `Hex.pm` using its restful
%%% API. *Note* The `Hex.pm` api is rate limited. Roughly 100 requests
%%% in 60 seconds is The maximum allowed. We add a limit here of 1
%%% request every second to make sure we don't go over that. If any
%%% call Fails here, the entire process fails.
%%% ---------------------------------------------------------------------------
-module(h2n_fetcher).

%%
%% API
%%
-export([update_with_information_from_hex_pm/3,
         get_registry/2]).

%%
%% Imports
%%
-include("hex2nix.hrl").

%%
%% Types
%%
-export_type([license/0
             , link/0
             , position/0
             , dep_desc/0
             , sha/0]).

-type license() :: binary().
-type description() :: binary() | none.
-type link() :: binary() | no_source.
-type position() :: root | historical.
-type dep_desc() :: #dep_desc{}.
-type sha() :: binary(). %% A sha 256 hash

%%
%% Definitions
%%

-define(CACHE_FILE, ".hex2nix.cache").
-define(CACHE_REGISTRY_FILE, ".hex2nix.registry.cache").
-define(DEFAULT_CDN, "http://s3.amazonaws.com/s3.hex.pm/tarballs").


%% ============================================================================
%% Exported Functions
%% ============================================================================
-spec update_with_information_from_hex_pm(boolean()
                                         , hex2nix:deps()
                                         , [h2n_resolver:app_dep()]) ->
                                         [dep_desc()].
update_with_information_from_hex_pm(true, AllApps, Deps) ->
    Cache =
        case h2n_util:consult(?CACHE_FILE) of
            {ok, [CachedDeps]} ->
                io:format("Loading available deps information from cache: ~s~n",
                          [?CACHE_FILE]),
                CachedDeps;
            _ ->
                []
        end,
    NewDeps = update_with_information_from_hex_pm2(AllApps, Cache, Deps),
    %% Write back to cache with newer data earlier on the list, so
    %% lists:keysearch will pick it up earlier.
    ec_file:write_term(?CACHE_FILE, NewDeps ++ Cache),
    NewDeps;
update_with_information_from_hex_pm(false, AllApps, Deps) ->
    update_with_information_from_hex_pm2(AllApps, [], Deps).

-spec get_registry(boolean(), file:filename()) ->  [any()].
get_registry(ShouldCache, HexRegistry) ->
    RegistryFile =
        case ShouldCache andalso filelib:is_regular(?CACHE_REGISTRY_FILE) of
            false ->
                TempDirectory = h2n_util:temp_directory(),
                io:format("Pulling Hex Registry From ~s to ~s~n"
                         , [HexRegistry, TempDirectory]),
                {ok, "200", _, {file, GzippedFileName}} =
                    ibrowse:send_req(HexRegistry
                                    , []
                                    , get
                                    , []
                                    , [{save_response_to_file,
                                        filename:join(TempDirectory, "registry.ets.gz")}
                                      | h2n_util:get_ibrowse_http_env()]),
                {ok, RF} = decompress_file(GzippedFileName, TempDirectory),
                case ShouldCache of
                    true ->
                        file:copy(RF, ?CACHE_REGISTRY_FILE);
                    false -> ok
                end,
                RF;
            true ->
                ?CACHE_REGISTRY_FILE
        end,
    {ok, RegistryTable} = ets:file2tab(RegistryFile),
    ets:tab2list(RegistryTable).


%% ============================================================================
%% Internal Functions
%% ============================================================================

-spec decompress_file(file:filename(), file:filename()) ->
                             {ok, file:filename()}.
decompress_file(GzippedFileName, TargetDirectory) ->
    ResultFile = filename:join(TargetDirectory, "registry.ets"),
    {ok, Data} = file:read_file(GzippedFileName),
    UncompressedData = zlib:gunzip(Data),
    file:write_file(ResultFile, UncompressedData, []),
    io:format("File uncompressed to ~s~n", [ResultFile]),
    {ok, ResultFile}.

-spec update_with_information_from_hex_pm2(hex2nix:deps(),
                                           [dep_desc()],
                                           [h2n_resolver:app_dep()]) ->
                                                  [dep_desc()].
update_with_information_from_hex_pm2(AllApps, Cache, Deps) ->
    lists:filtermap(
      fun (AppDep={App={AppName, AppVsn}, _Deps}) ->
              case lists:keysearch(App, #dep_desc.app, Cache) of
                  {value, Cached} ->
                      io:format("Found ~s ~s details in cache.~n", [AppName, AppVsn]),
                      {true, Cached};
                  false ->
                      io:format("Fetching ~s ~s details from hex.pm.~n", [AppName, AppVsn]),
                      decorate_app(AllApps, AppDep)
              end
      end, Deps).

-spec decorate_app(hex2nix:deps(), {hex2nix:app(), [hex2nix:app()]}) ->
                          {true, dep_desc()} | false.
decorate_app(#indexed_deps{roots=Roots} = AllApps,
             {App={AppName, AppVsn}, Deps}) ->
    IsRoot = case sets:is_element(App, Roots) of
                 true ->
                     root;
                 false ->
                     historical
             end,
    {Description, Licenses, Link} =
        get_metadata(AppName, get_app_detail_from_hex_pm(AppName)),
    case get_deep_meta_for_package(AppName, AppVsn, AllApps) of
        {Sha, HasNativeCode, BuildPlugins, BuildTool} ->
            {true, #dep_desc{app = App
                            , description = Description
                            , position = IsRoot
                            , licenses = Licenses
                            , homepage = Link
                            , sha = Sha
                            , build_plugins = BuildPlugins
                            , has_native_code = HasNativeCode
                            , build_tool = BuildTool
                            , deps = Deps}};
        no_metadata_available ->
            false
    end.

-spec get_app_detail_from_hex_pm(binary()) -> jsx:json_term().
get_app_detail_from_hex_pm(AppName) ->
    Thunk =
        fun() ->
                Url = h2n_util:iolist_to_list(["https://hex.pm/api/packages/"
                                              , AppName]),
                ibrowse:send_req(Url
                                , [{"Accept", "application/json"}]
                                , get
                                , []
                                , h2n_util:get_ibrowse_http_env())
        end,
    {ok, "200", _, Body} =
        take_at_least_one_second(Thunk),
    jsx:decode(erlang:iolist_to_binary(Body)).

-spec get_deep_meta_for_package(hex2nix:app_name()
                               , hex2nix:app_version()
                               , hex2nix:deps()) ->
                                       {sha(), boolean(), [hex2nix:app_name()],
                                        hex2nix:build_systems()} | no_metadata_available.
get_deep_meta_for_package(AppName, AppVsn, AllApps) ->
    TempDirectory = h2n_util:temp_directory(),
    Package = binary_to_list(<<AppName/binary, "-", AppVsn/binary, ".tar">>),
    TargetPath = filename:join(TempDirectory, Package),
    Url = h2n_util:iolist_to_list([?DEFAULT_CDN, "/", Package]),
    io:format("Pulling From ~s to ~s~n"
             , [Url, TargetPath]),
    case ibrowse:send_req(Url
                         , []
                         , get
                         , []
                         , [{save_response_to_file,
                             TargetPath}
                            | h2n_util:get_ibrowse_http_env()]) of
        {ok, "200", _, {file, DownloadedPath}} ->
            [Sha | _]  = string:tokens(h2n_util:cmd("sha256sum \"~s\"", [DownloadedPath]),
                                       " "),
            {HasNativeCode, BuildPlugins, BuildTool} =
                has_native_code_and_plugins(AppName, TempDirectory, TargetPath, AllApps),
            {erlang:list_to_binary(Sha), HasNativeCode, BuildPlugins, BuildTool};
        _ ->
            no_metadata_available
    end.

-spec has_native_code_and_plugins(hex2nix:app_name(),
                                  file:filename(),
                                  file:filename(),
                                  hex2nix:deps())
                                 -> {boolean(), [hex2nix:app_name()]}.
has_native_code_and_plugins(AppName, TempDirectory, TargetPath, AllApps) ->
    ok = erl_tar:extract(TargetPath, [{cwd, TempDirectory}]),
    ContentsPath = filename:join(TempDirectory, "contents.tar.gz"),
    {ok, DirListing} = erl_tar:table(ContentsPath, [compressed]) ,
    HasCSrc = lists:any(fun(Path) ->
                                lists:prefix("c_src/", Path)
                        end, DirListing),
    ok = erl_tar:extract(ContentsPath, [{cwd, TempDirectory}
                                       , {files, ["rebar.config"]},
                                        compressed]),
    {HasPortSpec, BuildPlugins0} = analyze_rebar_config(TempDirectory,
                                                        DirListing),
    BuildPlugins = filter_out_unknown_plugins(AppName, BuildPlugins0, AllApps),
    BuildTool  = get_build_tool(TempDirectory),
    {HasCSrc orelse HasPortSpec, BuildPlugins, BuildTool}.

-spec get_build_tool(file:name()) -> hex2nix:build_systems().
get_build_tool(MetadataDirectory) ->
    {ok, Items} = h2n_util:consult(filename:join(MetadataDirectory, "metadata.config")),
    case lists:keysearch(<<"build_tools">>, 1, Items) of
        {value, {_, BuildTools}} ->
            resolve_build_tool(BuildTools);
        false ->
            rebar3
    end.

-spec resolve_build_tool([binary()] | binary()) -> hex2nix:build_systems().
resolve_build_tool(AppList) when erlang:is_list(AppList) ->
    lists:foldl(fun resolve_build_tool/2, rebar3, AppList).

-spec resolve_build_tool([binary()] | binary(), any()) -> hex2nix:build_systems().
resolve_build_tool(<<"rebar3">>, rebar3) ->
    rebar3;
resolve_build_tool(<<"make">>, _) ->
    erlang_mk;
resolve_build_tool(<<"rebar">>, rebar3) ->
    rebar3;
resolve_build_tool(<<"mix">>, _) ->
    mix;
resolve_build_tool(<<"erlang.mk">>, _) ->
    erlang_mk;
resolve_build_tool(_, Current) ->
    Current.

-spec analyze_rebar_config(file:filename(), [file:filename()]) -> {boolean(), [hex2nix:app_name()]}.
analyze_rebar_config(TempDirectory, DirListing) ->
    case h2n_util:consult(filename:join(TempDirectory, "rebar.config")) of
        {ok, Options} ->
            PluginDir = proplists:get_value(plugin_dir, Options, "src/"),
            Plugins = proplists:get_value(plugins, Options, []),
            BuildPlugins = filter_out_local_plugins(
                             PluginDir,
                             DirListing,
                             lists:map(fun simplify_plugin/1,
                                       Plugins)),
            {compile_ports_heuristic(Options), BuildPlugins};
        _ ->
            {false, []}
    end.

-spec filter_out_unknown_plugins(hex2nix:app_name(),
                                 [hex2nix:app_name()],
                                 hex2nix:deps())
                                -> [hex2nix:app_name()].
filter_out_unknown_plugins(AppName, BuildPlugins, #indexed_deps{index = All}) ->
    {Good, Dropped} = lists:partition(
                 fun(Plugin) ->
                         dict:is_key(Plugin, All)
                 end, BuildPlugins),
    case Dropped of
        [] -> ok;
        _ ->
            io:format("Filtered out unknown and non-local plugins ~s for ~p~n",
                      [Dropped, AppName])
    end,
    Good.

-spec filter_out_local_plugins(file:filename(),
                               [file:filename()],
                               [hex2nix:app_name()]) ->
                                      [hex2nix:app_name()].
filter_out_local_plugins(PluginDir, DirListing, BuildPlugins) ->
    lists:filter(
      fun(Plugin) ->
              not lists:member(filename:join(PluginDir, binary_to_list(Plugin) ++ ".erl"),
                               DirListing)
      end, BuildPlugins).


-spec compile_ports_heuristic([term()]) -> boolean().
compile_ports_heuristic(Options) ->
    lists:keymember("port_spec", 1, Options)
        orelse lists:keymember("port_env", 1, Options)
        orelse lists:keymember("port_sources", 1, Options).

-spec simplify_plugin(atom()
                      | {atom(), any()}
                      | {atom(), any(), any()}) -> binary().
simplify_plugin({Name, _Vsn, _Vcs}) when is_atom(Name) ->
    simplify_plugin(Name);
simplify_plugin({Name, _Vsn}) when is_atom(Name) ->
    simplify_plugin(Name);
simplify_plugin(Name) when is_atom(Name) ->
    atom_to_binary(Name, latin1).

-spec get_metadata(hex2nix:app_name(), {[{binary(), binary()}]} | any()) ->
                          {description(), [license()], link()}.
get_metadata(AppName, Object)
  when erlang:is_list(Object) ->
    {ok, Meta} = h2n_util:json_get_assoc_list(<<"meta">>, Object),
    Description = get_description(Meta),
    Licenses = parse_license(AppName
                            , h2n_util:json_get_list(<<"licenses">>, Meta)),
    Link = parse_links(AppName
                      , h2n_util:json_get_assoc_list(<<"links">>, Meta)),
    {Description, Licenses, Link};
get_metadata(AppName, _) ->
    io:format("Invalid metadata for ~s~n", [AppName]),
    erlang:halt(1).

-spec get_description([{binary(), jsx:json_term()}]) -> binary() | none.
get_description(Meta) ->
    case lists:keysearch(<<"description">>, 1, Meta) of
        {value, {_, Description}} when erlang:is_binary(Description) ->
            Description;
        _ ->
            none
    end.

-spec parse_links(binary(),
                  {ok, [{binary(), jsx:json_term()}] | jsx:json_term()} | false) ->
                         link().
parse_links(Name, {ok, Links})
  when erlang:is_list(Links) ->
    get_website_link(Name, lists:map(fun({Key, Link}) ->
                                                {h2n_util:binary_to_lower(Key)
                                                , Link}
                                     end,
                                     Links));
parse_links(Name, false) ->
    io:format("No homepage link for ~s~n", [Name]),
    no_source.



-spec get_website_link(hex2nix:app_name(), [{binary(), jsx:json_term()}]) -> link().
get_website_link(Name, Links)
  when erlang:is_list(Links) ->
    case lists:keysearch(<<"website">>, 1, Links) of
        {value, {_, Link}} when erlang:is_binary(Link) ->
            Link;
        _ ->
            get_source_link(Name, Links)
    end.

-spec get_source_link(hex2nix:app_name(), [{binary(), jsx:json_term()}]) -> link().
get_source_link(Name, Links) ->
    case lists:keysearch(<<"source">>, 1, Links) of
        {value, {_, Link}} when erlang:is_binary(Link) ->
            Link;
        _ ->
            get_github_link(Name, Links)
    end.

-spec get_github_link(hex2nix:app_name(), [{binary(), binary()}]) -> link().
get_github_link(Name, Links) ->
    case lists:keysearch(<<"github">>, 1, Links) of
        {value, {_, Link}} when erlang:is_binary(Link) ->
            Link;
        _ ->
            io:format("No website link found for ~p~n", [Name]),
            no_source
    end.

%% This defaults to the generic 'free' license. I don't like that, but
%% the hex api allows free form license names that means that we can't
%% anticipate all the possible types of licenses. Hopefully, we cover
%% the majority here.
-spec parse_license(hex2nix:app_name()
                   , {ok, [jsx:json_term()]| jsx:json_term()} | false) ->
                           [license()].
parse_license(Name, {ok, Licenses}) when erlang:is_list(Licenses) ->
    lists:map(fun(License) ->
                      parse_license0(Name, License)
              end, Licenses);
parse_license(Name, _) ->
    io:format("Unable to parse license for ~s. Using "
              "'Unspecified free software license'~n", [Name]),
    [<<"free">>].

-spec parse_license0(hex2nix:app_name(),
                     jsx:json_term()) -> license().
parse_license0(Name, License) when erlang:is_binary(License) ->
    parse_license1(Name,
                   erlang:list_to_binary(
                     string:to_lower(erlang:binary_to_list(License))));
parse_license0(Name, _) ->
    io:format("Unable to parse license for ~s. Using "
              "'Unspecified free software license'~n", [Name]),
    <<"free">>.

-spec parse_license1(hex2nix:app_name(), binary()) -> license().
parse_license1(_Name, <<"zpl-2.1">>) -> <<"zpt21">>;
parse_license1(_Name, <<"zpl 2.1">>) -> <<"zpt21">>;
parse_license1(_Name, <<"zpl-2.0">>) -> <<"zpt20">>;
parse_license1(_Name, <<"zpl 2.0">>) -> <<"zpt20">>;
parse_license1(_Name, <<"zlib">>) -> <<"zlib">>;
parse_license1(_Name, <<"w3c">>) -> <<"w3c">>;
parse_license1(_Name, <<"vsl-1.0">>) -> <<"vsl10">>;
parse_license1(_Name, <<"vsl 1.0">>) -> <<"vsl10">>;
parse_license1(_Name, <<"vim">>) -> <<"vim">>;
parse_license1(_Name, <<"tcl">>) -> <<"tcltk">>;
parse_license1(_Name, <<"sleepycat">>) -> <<"sleepycat">>;
parse_license1(_Name, <<"sgi-b-2.0">>) -> <<"sgi-b-20">>;
parse_license1(_Name, <<"sgi b 2.0">>) -> <<"sgi-b-20">>;
parse_license1(_Name, <<"ruby">>) -> <<"ruby">>;
parse_license1(_Name, <<"qwt">>) -> <<"qwt">>;
parse_license1(_Name, <<"qpl-1.0">>) -> <<"qpll">>;
parse_license1(_Name, <<"qpl 1.0">>) -> <<"qpll">>;
parse_license1(_Name, <<"public domain">>) -> <<"publicDomain">>;
parse_license1(_Name, <<"python-2.0">>) -> <<"psfl">>;
parse_license1(_Name, <<"postgresql">>) -> <<"postgresql">>;
parse_license1(_Name, <<"php-3.01">>) -> <<"php301">>;
parse_license1(_Name, <<"php 3.01">>) -> <<"php301">>;
parse_license1(_Name, <<"oppenssl-2.0">>) -> <<"openssl">>;
parse_license1(_Name, <<"oppenssl 2.0">>) -> <<"openssl">>;
parse_license1(_Name, <<"oldap-2.0">>) -> <<"openldap">>;
parse_license1(_Name, <<"oldap 2.0">>) -> <<"openldap">>;
parse_license1(_Name, <<"ofl-1.1">>) -> <<"ofl">>;
parse_license1(_Name, <<"ofl 1.1">>) -> <<"ofl">>;
parse_license1(_Name, <<"ncsa">>) -> <<"ncsa">>;
parse_license1(_Name, <<"msrla">>) -> <<"msrla">>;
parse_license1(_Name, <<"mpl 2.0">>) -> <<"mpl20">>;
parse_license1(_Name, <<"mpl-2.0">>) -> <<"mpl20">>;
parse_license1(_Name, <<"mpl-1.1">>) -> <<"mpl11">>;
parse_license1(_Name, <<"mpl 1.1">>) -> <<"mpl11">>;
parse_license1(_Name, <<"mpl-1.0">>) -> <<"mpl10">>;
parse_license1(_Name, <<"mpl 1.0">>) -> <<"mpl10">>;
parse_license1(_Name, <<"lpl-1.02">>) -> <<"lpl-102">>;
parse_license1(_Name, <<"lpl 1.02">>) -> <<"lpl-102">>;
parse_license1(_Name, <<"llppl-1.3c">>) -> <<"lppl13c">>;
parse_license1(_Name, <<"llppl 1.3c">>) -> <<"lppl13c">>;
parse_license1(_Name, <<"llppl-1.2">>) -> <<"lppl12">>;
parse_license1(_Name, <<"llppl 1.2">>) -> <<"lppl12">>;
parse_license1(_Name, <<"llgpl-2.1">>) -> <<"llgpl21">>;
parse_license1(_Name, <<"llgpl 2.1">>) -> <<"llgpl21">>;
parse_license1(_Name, <<"libtiff">>) -> <<"libtiff">>;
parse_license1(_Name, <<"libpng">>) -> <<"libpng">>;
parse_license1(_Name, <<"lgpl-3.0+">>) -> <<"lpgl3Plus">>;
parse_license1(_Name, <<"lgpl 3.0+">>) -> <<"lpgl3Plus">>;
parse_license1(_Name, <<"lgpl-3.0">>) -> <<"lpgl3">>;
parse_license1(_Name, <<"lgpl 3.0">>) -> <<"lpgl3">>;
parse_license1(_Name, <<"lgpl">>) -> <<"lpgl3">>;
parse_license1(_Name, <<"lgpl-2.1+">>) -> <<"lpgl21Plus">>;
parse_license1(_Name, <<"lgpl 2.1+">>) -> <<"lpgl21Plus">>;
parse_license1(_Name, <<"lgpl-2.1">>) -> <<"lpgl1">>;
parse_license1(_Name, <<"lgpl 2.1">>) -> <<"lpgl1">>;
parse_license1(_Name, <<"lgpl-2.0+">>) -> <<"lpgl2Plus">>;
parse_license1(_Name, <<"lgpl 2.0+">>) -> <<"lpgl2Plus">>;
parse_license1(_Name, <<"lgpl-2.0">>) -> <<"lpgl2">>;
parse_license1(_Name, <<"lgpl 2.0">>) -> <<"lpgl2">>;
parse_license1(_Name, <<"ipl-1.0">>) -> <<"ipl10">>;
parse_license1(_Name, <<"ipl 1.0">>) -> <<"ipl10">>;
parse_license1(_Name, <<"IPA">>) -> <<"ipa">>;
parse_license1(_Name, <<"IJG">>) -> <<"ijg">>;
parse_license1(_Name, <<"iasl">>) -> <<"iasl">>;
parse_license1(_Name, <<"gpl-3.0+">>) -> <<"gpl3Plus">>;
parse_license1(_Name, <<"gpl 3.0+">>) -> <<"gpl3Plus">>;
parse_license1(_Name, <<"gpl-3.0">>) -> <<"gpl3">>;
parse_license1(_Name, <<"gnu gplv3">>) -> <<"gpl3">>;
parse_license1(_Name, <<"gpl">>) -> <<"gpl3">>;
parse_license1(_Name, <<"gpl 3.0">>) -> <<"gpl3">>;
parse_license1(_Name, <<"gpl-2.0+">>) -> <<"gpl2Plus">>;
parse_license1(_Name, <<"gpl 2.0+">>) -> <<"gpl2Plus">>;
parse_license1(_Name, <<"gpl-2.0">>) -> <<"gpl2">>;
parse_license1(_Name, <<"gpl 2.0">>) -> <<"gpl2">>;
parse_license1(_Name, <<"gfdl-1.3">>) -> <<"fdl13">>;
parse_license1(_Name, <<"gfdl 1.3">>) -> <<"fdl13">>;
parse_license1(_Name, <<"gfdl-1.2">>) -> <<"fdl12">>;
parse_license1(_Name, <<"gfdl 1.2">>) -> <<"fdl12">>;
parse_license1(_Name, <<"epl-1.0">>) -> <<"epl10">>;
parse_license1(_Name, <<"epl 1.0">>) -> <<"epl10">>;
parse_license1(_Name, <<"epl 1.1">>) -> <<"epl10">>;
parse_license1(_Name, <<"efl-2.0">>) -> <<"efl20">>;
parse_license1(_Name, <<"efl 2.0">>) -> <<"efl20">>;
parse_license1(_Name, <<"efl-1.0">>) -> <<"efl10">>;
parse_license1(_Name, <<"efl 1.0">>) -> <<"efl10">>;
parse_license1(_Name, <<"cpl-1.0">>) -> <<"cpl10">>;
parse_license1(_Name, <<"cpl 1.0">>) -> <<"cpl10">>;
parse_license1(_Name, <<"cecill-c">>) -> <<"cecill-c">>;
parse_license1(_Name, <<"cecill c">>) -> <<"cecill-c">>;
parse_license1(_Name, <<"cecill-2.0">>) -> <<"cecill20">>;
parse_license1(_Name, <<"cecill 2.0">>) -> <<"cecill20">>;
parse_license1(_Name, <<"cddl">>) -> <<"cddl">>;
parse_license1(_Name, <<"cddl-1.0">>) -> <<"cddl">>;
parse_license1(_Name, <<"cddl 1.0">>) -> <<"cddl">>;
parse_license1(_Name, <<"cc-by-sa-4.0">>) -> <<"cc-by-sa-40">>;
parse_license1(_Name, <<"cc by sa 4.0">>) -> <<"cc-by--sa 40">>;
parse_license1(_Name, <<"cc-by-4.0">>) -> <<"cc-by-40">>;
parse_license1(_Name, <<"cc by 4.0">>) -> <<"cc-by-40">>;
parse_license1(_Name, <<"cc-by-sa-3.0">>) -> <<"cc-by-sa-30">>;
parse_license1(_Name, <<"cc-by-3.0">>) -> <<"cc-by-30">>;
parse_license1(_Name, <<"cc by 3.0">>) -> <<"cc-by-30">>;
parse_license1(_Name, <<"cc-by-sa-2.5">>) -> <<"cc-by-sa-25">>;
parse_license1(_Name, <<"cc by sa 2.5">>) -> <<"cc-by-sa-25">>;
parse_license1(_Name, <<"cc0-1.0">>) -> <<"cc0">>;
parse_license1(_Name, <<"cc0 1.0">>) -> <<"cc0">>;
parse_license1(_Name, <<"cc0">>) -> <<"cc0">>;
parse_license1(_Name, <<"bsd-3">>) -> <<"bsd3">>;
parse_license1(_Name, <<"bsd 3">>) -> <<"bsd3">>;
parse_license1(_Name, <<"bsd 3.0">>) -> <<"bsd3">>;
parse_license1(_Name, <<"the bsd 3-clause license">>) -> <<"bsd3">>;
parse_license1(_Name, <<"bsd 3-clause">>) -> <<"bsd3">>;
parse_license1(_Name, <<"bsd-2">>) -> <<"bsd2">>;
parse_license1(_Name, <<"bsd 2">>) -> <<"bsd2">>;
parse_license1(_Name, <<"bsd-2 clause">>) -> <<"bsd2">>;
parse_license1(_Name, <<"simplified bsd">>) -> <<"bsd2">>;
parse_license1(_Name, <<"bsl-1.0">>) -> <<"boost">>;
parse_license1(_Name, <<"apache license 2.0">>) -> <<"asl20">>;
parse_license1(_Name, <<"bsl 1.0">>) -> <<"boost">>;
parse_license1(_Name, <<"apache-2.0">>) -> <<"asl20">>;
parse_license1(_Name, <<"apache 2.0">>) -> <<"asl20">>;
parse_license1(_Name, <<"apache v2.0">>) -> <<"asl20">>;
parse_license1(_Name, <<"apl 2.0">>) -> <<"asl20">>;
parse_license1(_Name, <<"artistic-1.0">>) -> <<"artistic1">>;
parse_license1(_Name, <<"artistic 1.0">>) -> <<"artistic1">>;
parse_license1(_Name, <<"artistic">>) -> <<"artistic1">>;
parse_license1(_Name, <<"apsl-2.0">>) -> <<"apsl20">>;
parse_license1(_Name, <<"apsl 2.0">>) -> <<"apsl20">>;
parse_license1(_Name, <<"agpl-3.0">>) -> <<"agpl3">>;
parse_license1(_Name, <<"agpl 3.0">>) -> <<"agpl3">>;
parse_license1(_Name, <<"afl-2.1">>) -> <<"afl21">>;
parse_license1(_Name, <<"afl 2.1">>) -> <<"afl21">>;
parse_license1(_Name, <<"apache 2">>) -> <<"apsl20">>;
parse_license1(_Name, <<"apache">>) -> <<"apsl20">>;
parse_license1(_Name, <<"unlicense">>) -> <<"unlicense">>;
parse_license1(_Name, <<"mozilla public license 1.1">>) -> <<"mpl11">>;
parse_license1(_Name, <<"mozilla public license version 2.0">>) -> <<"mpl20">>;
parse_license1(_Name, <<"isc">>) -> <<"isc">>;
parse_license1(_Name, <<"the mit license (mit)">>) -> <<"mit">>;
parse_license1(_Name, <<"mit license">>) -> <<"mit">>;
parse_license1(_Name, <<"gpl (for code)">>) -> <<"gpl3">>;
parse_license1(_Name, <<"bsd (for code)">>) -> <<"bsd3">>;
parse_license1(_Name, <<"mit">>) -> <<"mit">>;
parse_license1(_Name, <<"bsd">>) -> <<"bsd3">>;
parse_license1(_Name, <<"wtfpl">>) -> <<"wtfpl">>;
parse_license1(_Name, <<"do what the fuck you want to public license (wtfpl)">>) -> <<"wtfpl">>;
parse_license1(_Name, <<"do what the f*ck you want">>) -> <<"wtfpl">>;
parse_license1(_Name, <<"the mit license">>) -> <<"mit">>;
parse_license1(_Name, <<"same as elixir">>) -> <<"asl20">>;
parse_license1(Name, License) ->
    io:format("Unable to parse license ~s for ~s. Using "
              "'Unspecified free software license'~n", [License, Name]),
    <<"free">>.

%% @doc This exists to get around a rate limiter. Essentially, hex
%% limits us to one request per second. This allows us to do that.
-spec take_at_least_one_second(fun(() -> Result)) -> Result.
take_at_least_one_second(Thunk) ->
    Start = erlang:system_time(milli_seconds),
    Result = Thunk(),
    Now = erlang:system_time(milli_seconds),
    Wait = Now - Start,
    case Wait > 1000 of
        true ->
            Result;
        false ->
            timer:sleep(1000 - Wait),
            Result
    end.
