ExUnit.start()

{:ok, _} = Clawrig.TestSupport.MockTelegramHTTP.start_link([])
{:ok, _} = Clawrig.TestSupport.MockBrowserUseBrokerHTTP.start_link([])
{:ok, _} = Clawrig.TestSupport.MockSearchProxyHTTP.start_link([])
