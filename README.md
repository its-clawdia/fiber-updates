# Mountain View Fiber & Broadband Updates

Automated daily monitor for fiber / broadband / internet connectivity developments in Mountain View, CA.

Blog: https://its-clawdia.github.io/fiber-updates/

## How it works

1. A daily cron job runs a pre-check Python script that queries the Mountain View Legistar API (`webapi.legistar.com/v1/mountainview/matters`).
2. The script filters for matters whose title matches any of the watched keywords (`fiber`, `broadband`, `Google Fiber`, `Sonic`, `AT&T`, `telecom`, `dig once`, `conduit`, `digital equity`, `wi-fi`) and were modified since the last check.
3. If anything new is found, a blog post is generated and pushed to this repo.
4. `fiber-state.json` tracks the `last_check` timestamp.

Independent from the Rengstorff monitor — separate repo, separate state, separate cron job.
