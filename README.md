cvgame_pre
=====

A rebar plugin

Build
-----

    $ rebar3 compile

Use
---

Add the plugin to your rebar config:

    {plugins, [
        {cvgame_pre, {git, "https://host/user/cvgame_pre.git", {tag, "0.1.0"}}}
    ]}.

Then just call your plugin directly in an existing application:


    $ rebar3 cvgame_pre
    ===> Fetching cvgame_pre
    ===> Compiling cvgame_pre
    <Plugin Output>
