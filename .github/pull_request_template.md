## Summary

- What changed
- Why it changed

## Reviewer Guide

- Highest-risk area
- Best place to start reviewing

## Visual Aids

- Screenshots or screen recordings for UI, layout, animation, onboarding, or copy changes
- If not applicable, write `N/A`

## Validation

- [ ] `mise run verify`
- [ ] Affected shell exercised with `mise run harness -- exercise --platform <ios|watchos|tvos>`
- [ ] Proof captured with `mise run harness -- proof --platform <platform>`
- [ ] Proof published separately with `mise run harness -- publish --artifact <path> --repo putdotio/putio-ios --pr <number>`
- Additional targeted checks:
  -

## Sanity Checks

- Manual user paths exercised
- Edge cases or failure paths checked
- If not applicable, write `N/A`

## Benchmarks

- Before and after numbers for performance-sensitive changes
- Startup, scrolling, memory, network, or build-time impact when relevant
- If not applicable, write `N/A`

## Notes

- Risks, rollout notes, or follow-up work
