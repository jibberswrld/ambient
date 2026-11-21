# Ambient interface captures

Rendered off screen by the demo, so nothing appears on the desktop while they are made:

    cd Packages/AmbientKit
    swift build --scratch-path .build-ui --product AmbientUIDemo
    .build-ui/debug/AmbientUIDemo --capture /tmp/ambient-captures --quit-after 400

- `flow-bar/` every bar state on the bottom and left edges, over a dark and a light desktop with a text window
  behind the bar. `-contrast` files force the Increase Contrast look.
- `windows/` settings (light and dark), onboarding (gate, permissions, first run) and the pointer.
- `sheets/` contact sheets of the above.

Glass in these files is simulated: the renderer draws each surface over a blurred copy of the backdrop, because live
Liquid Glass is composited by the window server and cannot be captured off screen.
