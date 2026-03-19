# Journey: Deploy Notification (End-to-End)

## Persona

**Dave Williams** -- solo developer. This journey traces the complete arc from "I want deploy notifs in Slackex" to "every deploy automatically appears in #deploys."

## Goal

Replace the existing Discord webhook in GitHub Actions CI with a Slackex webhook, so deploy notifications appear in the #deploys channel inside Slackex instead of Discord.

## Emotional Arc

```
Motivated ──> Focused ──> Testing ──> Relieved ──> Proud
"Time to      "Setting   "Does the   "It works,   "I'm eating
 dogfood      up the     curl test    first real    my own
 my app"      pieces"    work?"       deploy!"      dog food"
```

## End-to-End Flow

```
[Phase 1: Setup]           [Phase 2: Integration]       [Phase 3: Live]

Create webhook in          Update ci-deploy.yml         Push a tag,
Slackex for #deploys       to POST to Slackex           watch notification
channel                    instead of Discord           appear in #deploys
  |                          |                            |
  v                          v                            v
Get webhook URL            Replace DISCORD_WEBHOOK_URL   Deploy succeeds,
                           with SLACKEX_WEBHOOK_URL      message appears
  |                          |                            |
  v                          v                            v
Test with curl             Commit and push              Remove Discord
to verify it works         to master                    webhook (optional)
```

## Step Details

### Phase 1: Create Webhook in Slackex

Dave opens Slackex, navigates to webhook settings, creates a webhook:

- **Channel**: `#deploys` (auto-created if it doesn't exist)
- **Display Name**: `Deploy Bot`
- **Description**: `GitHub Actions deploy notifications`

Gets URL: `https://slackex.example.com/api/webhooks/whk_a1b2c3d4e5f6`

### Phase 2: Test with curl

Dave tests from his terminal before touching CI:

```bash
curl -X POST \
  -H "Content-Type: application/json" \
  -d '{"text": "**Test:** webhook is working!"}' \
  https://slackex.example.com/api/webhooks/whk_a1b2c3d4e5f6
```

Expected response: `{"ok": true}`

Dave switches to the Slackex #deploys channel and sees:

```
  [BOT] Deploy Bot                              3:15 PM
  Test: webhook is working!
```

**Emotional state**: Testing -> Relieved. The test message confirms the pipeline works end-to-end before touching CI.

### Phase 3: Update GitHub Actions

Dave updates `.github/workflows/ci-deploy.yml`:

**Before** (Discord):
```yaml
notify:
  name: Discord Notification
  steps:
    - name: Send Discord notification
      env:
        DISCORD_WEBHOOK_URL: ${{ secrets.DISCORD_WEBHOOK_URL }}
      run: |
        curl -sf -H "Content-Type: application/json" \
          -d '{"embeds": [{"title": "..."}]}' \
          "$DISCORD_WEBHOOK_URL"
```

**After** (Slackex):
```yaml
notify:
  name: Slackex Notification
  steps:
    - name: Send deploy notification
      env:
        SLACKEX_WEBHOOK_URL: ${{ secrets.SLACKEX_WEBHOOK_URL }}
      run: |
        SAFE_MSG=$(echo "$COMMIT_MSG" | head -1 | sed 's/\\/\\\\/g; s/"/\\"/g' | cut -c1-100)

        if [ "${{ needs.quality.result }}" = "failure" ]; then
          TEXT="**CI Failed: Quality**"
        elif [ "${{ needs.deploy.result }}" = "failure" ]; then
          TEXT="**CI Failed: Deploy**"
        else
          TEXT="**Deployed: ${{ github.ref_name }}**"
        fi

        TEXT="$TEXT\n\n**Repo:** ${{ github.repository }}"
        TEXT="$TEXT\n**Branch:** ${{ github.ref_name }}"
        TEXT="$TEXT\n**Commit:** \`${GITHUB_SHA::7}\` -- ${SAFE_MSG}"
        TEXT="$TEXT\n**Run:** [View logs](${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }})"

        curl -sf -H "Content-Type: application/json" \
          -d "{\"text\": \"${TEXT}\"}" \
          "$SLACKEX_WEBHOOK_URL"
```

### Phase 4: Add GitHub Secret

Dave adds `SLACKEX_WEBHOOK_URL` as a repository secret in GitHub Settings > Secrets and variables > Actions.

### Phase 5: First Real Deploy

Dave pushes a version tag. CI runs, deploy succeeds, and the notification appears in #deploys:

```
+------------------------------------------------------------------+
| #deploys                                                          |
+------------------------------------------------------------------+
|                                                                    |
|  [BOT] Deploy Bot                              4:22 PM            |
|  +------------------------------------------------------------+   |
|  | Deployed: v0.5.81                                           |   |
|  |                                                             |   |
|  | Repo: davewil/slackex                                       |   |
|  | Branch: master                                              |   |
|  | Commit: 07c9eb7 -- feat: incoming webhooks                  |   |
|  | Run: View logs                                              |   |
|  +------------------------------------------------------------+   |
|                                                                    |
+------------------------------------------------------------------+
```

**Emotional state**: Proud. Dave is dogfooding his own app for real infrastructure notifications.

## Error Paths

| Error | When | What Happens | Recovery |
|-------|------|-------------|----------|
| Webhook URL not set as secret | Phase 4 skipped | CI job fails with empty URL | Add the secret in GitHub |
| Slackex is down during deploy | Phase 5 | curl returns connection error, CI job may fail | Make notification step `continue-on-error: true` |
| Token was regenerated | After Phase 4 | CI gets 401 from Slackex | Update the GitHub secret with new URL |
| Payload too large | Commit message very long | 413 from Slackex | Truncate commit message (already done with `cut -c1-100`) |

## Migration Checklist

- [ ] Create webhook in Slackex, get URL
- [ ] Test with curl locally
- [ ] Add `SLACKEX_WEBHOOK_URL` secret to GitHub repo
- [ ] Update `ci-deploy.yml` notify job
- [ ] Push a test tag to verify end-to-end
- [ ] (Optional) Remove `DISCORD_WEBHOOK_URL` secret after confidence period
