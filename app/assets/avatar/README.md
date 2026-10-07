# Avatar stages

The companion screen prefers stages in this order, falling back silently:

1. **3D** (`avatar_3d_stage.dart`) — real-time GLB below, on phones.
2. **Video** (`avatar_video_stage.dart`) — bundled Juno clips: `juno_idle.mp4`,
   `juno_orb.mp4`, `juno_typing.mp4`, `juno_talking.mp4` (one per pose).
3. **Pixel** (`pixel_stage.dart`) — the 64x64-style portrait, also what widget
   tests render.

## Current model: `duck.glb` (placeholder)

- **Source:** Gobkit Free Animal Pack (https://gobkit.itch.io/gobkit-free-animal-pack)
- **License:** CC0 1.0 (public domain) — free for any use, commercial or personal, no attribution required
- **Direct URL:** https://gobkit.com/freebies/animal/Duck.glb
- **Size:** ~101 KB
- **Animations (named clips):** `idle`, `attack`, `dead`, `walk`
- **Skeleton:** 16 joints including `Mouth` (beak) and `Head` bones

## Pose → animation mapping (in `avatar_3d_stage.dart`)

| AvatarPose | Animation | Notes |
|------------|-----------|-------|
| idle | `idle` (loop) | Breathing loop |
| listening | `idle` (loop) | Same clip, camera leans in slightly |
| thinking | `walk` (loop, slow) | Pacing reads as "thinking" |
| speaking | `idle` + beak flap | Alternates `idle`/`attack` by TTS amplitude |

## Swapping in the real noir-duck model

To replace the placeholder with the real Juno noir-duck model:

1. Export your model as **GLB** (glTF binary) with baked animations
2. Name the animation clips to match the mapping above, OR update the mapping constants in `app/lib/ui/avatar_3d_stage.dart` (see `_poseAnimation`)
3. Replace `app/assets/avatar/duck.glb` with your file (keep the same filename, or update `avatarModelAsset` in `avatar_3d_stage.dart`)
4. Rebuild — no other code changes needed

The model path is isolated in one constant: `avatarModelAsset` in `app/lib/ui/avatar_3d_stage.dart`.
This is intentionally a one-line swap.
