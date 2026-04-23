# Conway's Game of Life with Metal

This project implements Conway's Game of Life on the GPU using Metal compute shaders, and displays the result in a SwiftUI app through `MTKView`.

<img src="assets/simulation.gif" alt="Simulation" width="520" />

## What the app does

- Simulates a 2D cellular automaton (Conway's Life)
- Updates the grid with a Metal compute kernel
- Renders the current grid texture with a Metal render pipeline
- Lets you Play/Pause, Step, Randomize, Clear, and change simulation speed

## Core equations

Let each cell state be:

$$
A_t(x,y) \in \{0,1\}
$$

where `1` means alive and `0` means dead at generation `t`.

Neighbor count:

$$
N_t(x,y) = \sum_{dx=-1}^{1}\sum_{dy=-1}^{1} A_t(x+dx,y+dy) - A_t(x,y)
$$

Transition rule:

$$
A_{t+1}(x,y) =
\begin{cases}
1, & \text{if } N_t(x,y)=3 \\
1, & \text{if } A_t(x,y)=1 \text{ and } N_t(x,y)=2 \\
0, & \text{otherwise}
\end{cases}
$$

This project uses **toroidal boundaries** (wrap-around edges):

$$
x' = (x + dx + W) \bmod W, \quad y' = (y + dy + H) \bmod H
$$

where `W` is grid width and `H` is grid height.

## GPU algorithm flow

1. Seed or clear state textures using compute kernels:
- `seedRandom`: writes random alive/dead values
- `clearState`: writes all dead cells

2. For each generation:
- `stepLife` reads from `current` texture and writes next generation to `next` texture
- texture indices are swapped (ping-pong buffering)

3. Render pass:
- `lifeVertex` outputs a fullscreen quad
- `lifeFragment` samples current state texture and maps alive/dead to colors

## Why two textures (ping-pong)

The next generation must be computed from the *unchanged* previous generation.
If we wrote updates into the same texture we are still reading from, results would be incorrect due to read/write hazards.

So we keep:
- `currentStateTexture` for reading
- `nextStateTexture` for writing

Then swap them each step.

## Simulation timing

Simulation speed is controlled in generations per second (`f`).

$$
\Delta t_{step} = \frac{1}{f}
$$

A time accumulator advances with frame delta time. While accumulator is greater than `Delta t_step`, the code runs another generation.
This keeps simulation rate stable even if render FPS changes.
