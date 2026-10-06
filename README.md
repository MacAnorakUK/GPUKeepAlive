# GPUKeepAlive

Menu bar workaround for scroll stutter on Studio Display XDR at 120Hz with M5 Pro MacBook Pros. Not an official fix.

## What it does

Some M5 Pro Macs show choppy scrolling on a Studio Display XDR at 120Hz or Adaptive refresh. Measurements by a MacRumors forum user suggest the GPU stays at a low clock speed while scrolling and misses frame deadlines. GPUKeepAlive gives the GPU a tiny Metal calculation about 120 times a second, so the clock speed stays up and scrolling stays smooth. The result of the calculation is thrown away.

This is a workaround, not a fix. Apple hasn't commented on the problem, and the explanation above is an informed theory, not a confirmed diagnosis.

Full write-up: [link to article]

## Behaviour

- Only runs when an external display faster than 60Hz is connected.
- Pauses when displays go to sleep and never stops your Mac sleeping.
- Never queues more than two frames of work.
- Intensity setting (Low, Medium, High, Very High). Medium was enough on my machine.
- The source contains no networking code and the app asks for no special permissions.]

## Install

You don't need coding experience. It takes about 10 minutes.

1. Click the green **Code** button above, then **Download ZIP**. Double-click the zip to unzip it. You should get a folder called `GPUKeepAlive-main` containing `main.swift` and `build.sh`.
2. Open Terminal (Cmd + Space, type Terminal, press Return) and run each command below, pressing Return after each.
3. `xcode-select --install` (installs Apple's free developer tools; click Install in the pop-up. This can take 5 to 15 minutes. If it says they're already installed, move on.)
4. `cd ~/Downloads/GPUKeepAlive-main`
5. `bash build.sh`. After a few seconds you should see "Built GPUKeepAlive.app".
6. `mv GPUKeepAlive.app /Applications/`
7. `open /Applications/GPUKeepAlive.app`

A lightning bolt appears in the menu bar. Click it and the top line should say something like "Active — Studio Display XDR @ 120 Hz". Try scrolling a web page. If it still stutters, raise Intensity one step. Tick **Launch at Login** to start it automatically.

If you can't see the bolt, your menu bar may be full, and on a MacBook the notch can hide icons. Quit another menu bar app to make room.

## Check that it's working

Run `sudo powermetrics --samplers gpu_power -i 500` in Terminal while scrolling and watch "GPU HW active frequency". With the app running, it should stay well above the 300–400MHz range.

## Uninstall

Choose **Quit** from the menu, then drag GPUKeepAlive from Applications to the Bin.

## Things to know

- Expect slightly higher power use and temperature. At Medium I couldn't hear the fans.
- Quit it before running GPU benchmarks.
- After a macOS update, quit the app once and scroll for a while. If the stutter has gone, Apple may have fixed the problem and you can delete the app.
- Tested on: [MacBook Pro model and chip], macOS [version], Studio Display XDR firmware [version]. Your results may differ.
- Use at your own risk. See the licence.

## Help get it fixed

If you're affected, file a report in Feedback Assistant. Include your Mac model and chip, macOS version, XDR firmware, and the fact that it appears at 120Hz or Adaptive but not 60Hz. If you can, attach `powermetrics` output captured while scrolling.

If you have an M5 Pro, a base M5 or an M5 Max and a high-refresh external display, I'd like to hear whether you see the stutter and whether the app helps. Details are in the article.

## Credit

The investigation behind this, including the GPU clock measurements and the idea of keeping the GPU busy, comes from tiguanito's [MacRumors forum thread](https://forums.macrumors.com/threads/studio-display-xdr-m5-pro-mbp-scrolling-stutter-at-120hz.2488232/). This is an independent implementation.

## Licence

MIT. See `LICENSE`.
