# The monthly support goal

Easy Cabinet asks its users to keep it alive: every month has a target (1000 USD to begin with). Users see how much of it has been reached. If the target is not
reached by the end of the grace days (the first 10 days of the month), the extension stops for them until it is, and shows the target, the amount reached and a
Donate button. **The author is never stopped** (see "Your own copy" below).

## What you have to set up

1. **A status file on the web** (any https address you control: GitHub Pages, a raw file in a repository, your own site):

   ```json
   { "month": "2026-11", "target": 1000, "raised": 372.5, "currency": "USD" }
   ```

   Update `raised` as donations arrive (by hand, or with a small script that reads your donation page). At the start of a month change `month` and set `raised`
   back to 0. A file that is not of the current month is ignored (the extension keeps working), so forgetting to roll it over never stops anyone.
2. **easy_cabinet/config.json**:

   | key | meaning |
   |---|---|
   | `status_url` | the address of the file above. Empty: the goal is off and nothing is ever stopped. |
   | `donation_url` | where the Donate button leads (https). |
   | `monthly_target` | the target when the file does not give one (1000). |
   | `currency` | the name shown with the amounts (USD). |
   | `grace_days` | the first days of a month in which the extension works whatever the amount (10; 0 to 28). |
   | `developer_hash` | the SHA-256 of your own key (below). |

## How it behaves

- The status is read in the background a few seconds after SketchUp starts, when the panel opens and then at most every 6 hours. Nothing about the user is sent.
- Whatever goes wrong (no connection, a damaged file, an old file) the extension **keeps working**. It is only stopped by a current status that says the month's
  target is not reached after the grace days. A status that could not be refreshed for 14 days is not trusted.
- Stopped means: every action of the panel and the menu commands are refused with the message; the panel shows the message, a progress bar, **Donate** and
  **I have donated: check again**. Nothing in the model is changed or deleted.

## Your own copy

The file `developer.key` in `%APPDATA%\SketchUp\EasyCabinet\` (it was made for you; the extension never includes it) holds the key whose SHA-256 is in `developer_hash`.
With that file in place the extension is never stopped on that computer. To use another key: write any text in `developer.key` and put the SHA-256 of that text
(without the trailing newline) in `developer_hash`.

## Be aware

- The code of an extension is open: someone who wants to can remove the check. This is a request to users, not a lock.
- **Extension Warehouse**: it expects an extension to work as advertised, so say in the description what the goal is, that the extension stops when it is not
  reached, and where the status is read from. Ask Trimble whether an extension that stops without a donation is accepted before you submit it.
