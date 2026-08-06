async def run_call_session(
    call_id: str,
    ws_url: str,          # Exotel media websocket
    lead_context: dict,   # name, history, campaign variables
    tools: ToolRegistry,
) -> CallResult: ...