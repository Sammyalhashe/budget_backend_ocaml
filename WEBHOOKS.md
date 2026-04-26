# Webhooks in Budget Backend

## What is a Webhook?
A webhook is an HTTP callback: an HTTP POST that occurs when something happens. In this project, Plaid "calls" your backend to notify it of events so you don't have to constantly poll their API.

## How they work in this project

### 1. The Entry Point
Your server listens for webhooks at:
`POST http://your-server.com/api/plaid/webhook`

### 2. The Flow
1. **Event Occurs:** A user connects a bank, or new transactions are imported by Plaid.
2. **Plaid Sends POST:** Plaid sends a JSON payload to your webhook endpoint.
3. **Verification:** The `Plaid_webhook` module (in `lib/plaid_webhook.ml`) receives the request.
4. **Action:**
   - If it's a `LINK` event, we save the tokens.
   - If it's an `ITEM` error, we mark the token as errored in the database.
   - If it's a `TRANSACTIONS` update, we can trigger a fresh sync.

## Real-time TUI Integration

Since you want a TUI that reacts in real-time, you shouldn't use webhooks directly in the TUI (because the TUI isn't a public web server). Instead, you use **WebSockets**.

### The "Reactive" Architecture:
1. **Plaid** sends a **Webhook** to your **Backend**.
2. Your **Backend** updates the **SQLite Database**.
3. Your **Backend** broadcasts a message over the **WebSocket** (`/api/plaid/ws`).
4. Your **TUI** (connected to the WebSocket) receives the message and refreshes its display immediately.

## Testing Webhooks Locally
Since Plaid cannot "see" your `localhost`, you can use a tool like `ngrok` to expose your port 5000, or you can mock them using Nushell:

```nushell
# Mock an error webhook
{
  webhook_type: "ITEM",
  webhook_code: "ERROR",
  item_id: "your_item_id",
  error: { error_code: "ITEM_LOGIN_REQUIRED" }
} | http post http://localhost:5000/api/plaid/webhook
```
