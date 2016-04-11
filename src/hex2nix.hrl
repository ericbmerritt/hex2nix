-record(indexed_deps, {roots :: sets:set(hex2nix:app()),
                       index :: dict:dict(hex2nix:app_name(), [hex2nix:app_version()]),
                       detail :: dict:dict(hex2nix:app(),
                                           hex2nix:registry_app())}).

-record(registry_app, {app :: hex2nix:app(),
                       deps :: hex2nix:app_deps_cons(),
                       build_tools :: hex2nix:build_tools()}).

-record(dep_desc, {app :: hex2nix:app(),
                   description :: h2n_fetcher:description(),
                   position :: h2n_fetcher:position(),
                   licenses :: [h2n_fetcher:license()],
                   homepage :: h2n_fetcher:link(),
                   sha :: h2n_fetcher:sha(),
                   build_tool :: hex2nix:recognized_build_tool(),
                   has_native_code :: boolean(),
                   build_plugins :: [hex2nix:app_name()],
                   deps :: [hex2nix:app()]}).

