[
  # phantom_mcp v0.3.4 library bug: Phantom.Router calls Phantom.Request.method_not_found/0
  # which doesn't exist. Cannot fix without forking. Track upstream for resolution.
  {"deps/phantom_mcp/lib/phantom/router.ex", :call_to_missing}
]
