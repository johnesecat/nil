# Nil: PowerShell Doom Engine

A fully functional, Doom-style 3D raycasting game that runs natively inside Windows 11 PowerShell via the Windows Terminal app. No external dependencies, no admin rights required.

## Features

- **DDA Raycasting Engine**: Authentic Wolfenstein 3D-style rendering using ANSI escape sequences.
- **Procedural Map Generation**: Cellular automata create unique cave-like levels every time.
- **Multi-Floor Support**: Explore 5 procedurally generated floors connected by stairs.
- **Enemy AI**: Enemies feature A* pathfinding, line-of-sight detection, and state machines (Idle/Chase/Attack).
- **Win32 Input**: Direct console input handling for smooth movement and low latency.

## Quick Start

### One-Click Install
Run this command in PowerShell:

```powershell
iwr -useb https://raw.githubusercontent.com/johnesecat/nil/main/install.ps1 | iex
