# Custom Mattermost ARM64 image based on rheens/mattermost-app:v11.3.0
# The original priv-entrypoint.sh does: chown + su mattermost (non-root)
# This breaks PVC writes because the non-root user can't access root-owned mounts.
# Solution: custom entrypoint runs as ROOT (runAsUser: 0 in deployment), 
# generates config.json, and starts mattermost directly.

FROM rheens/mattermost-app:v11.3.0

# Replace default entrypoint with our own
COPY custom-entrypoint.sh /custom-entrypoint.sh
RUN chmod +x /custom-entrypoint.sh

ENTRYPOINT ["/custom-entrypoint.sh"]
CMD ["mattermost"]
