# Auctionator (Ascension) — with a working "Chain buy"

A fork of [`Ascension-Addons/Auctionator`](https://github.com/Ascension-Addons/Auctionator)
(Auctionator by **Zirco**) that **completes the one-click "Chain buy"** and fixes the buy
loop so you can sweep up cheap stacks fast — e.g. 200 × single Linen Cloth — instead of
clicking Buy on every listing.

## Chain buy — how to use

On the **Buy** tab, search an item and click one of its listings to open the buy dialog.
Then:

1. Tick **Chain buy**.
2. Type how many you want, or **leave the amount blank to buy everything**.
3. Click **Buy** — once.

It buys the **cheapest listings first** and keeps going through pricier ones automatically
until the amount you entered is bought, you run out of gold, or there are none left. A
running "Bought xN for …" tally is shown, with a summary line when the sweep finishes.
Buying with **Chain buy unticked** works exactly as before (buys just the amount you type).

## What was fixed

Two things, both in `AuctionatorBuy.lua` (plus the Buy dialog in `Auctionator.xml`):

- **Chain buy was half-finished** — after each purchase it advanced to the next listing
  but then waited for another Buy click and reset the amount to 1, so there was no real
  "chain". It now sweeps in a single click.
- **The underlying buy fired every buyout in one frame.** On this server only the first
  completes per refresh; the rest fail with *"item not found"* (and the item count got
  over-counted). It now **buys one auction per refresh** and lets the list update before
  the next — reliable, at roughly one purchase per second.

## Install

**Easiest:** download the zip from [Releases](../../releases) (if published) and extract the
three folders into `Interface\AddOns\`.

**From source:** click **Code ▸ Download ZIP**, open the extracted `Auctionator-main`
folder, and copy these three folders into `Interface\AddOns\`, replacing the existing
`Auctionator`:

- `Auctionator`
- `Auctionator_Price_Database`
- `Auctionator_Pricing_History`

Your saved prices/settings are untouched — they live in `WTF`, not in the addon folder.

> ⚠️ **Launcher note:** Auctionator is installed by the Ascension launcher, so a launcher
> update may overwrite these files and revert the fix. If Chain buy stops working after an
> update, re-copy this addon. The clean long-term fix is to merge this upstream into
> `Ascension-Addons/Auctionator` so it ships to everyone.

## Credits

Auctionator by **Zirco**; Ascension port and the original chain-buy scaffolding by the
**[Ascension-Addons](https://github.com/Ascension-Addons/Auctionator)** contributors. This
fork only changes the buy behaviour described above.
