#!/usr/bin/env python3
import os
import urllib.request
import urllib.parse
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("whatsapp-mcp")


@mcp.tool()
def send_whatsapp(message: str) -> str:
    """Send a WhatsApp notification via the CallMeBot free API."""
    phone = os.environ["CALLMEBOT_PHONE"]
    apikey = os.environ["CALLMEBOT_APIKEY"]
    encoded = urllib.parse.quote(message)
    url = f"https://api.callmebot.com/whatsapp.php?phone={phone}&text={encoded}&apikey={apikey}"
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=15) as resp:
        body = resp.read().decode()
        return f"sent (HTTP {resp.status}): {body[:200]}"


if __name__ == "__main__":
    mcp.run()
