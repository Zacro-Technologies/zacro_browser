FROM node:24.22.1-bookworm-slim
ENV NODE_ENV=production ZACRO_SYNC_DATA=/data ZACRO_SYNC_PORT=4040
WORKDIR /app
COPY --chown=node:node services/sync/ ./
RUN mkdir /data && chown node:node /data
USER node
EXPOSE 4040
ENTRYPOINT ["node", "/app/cli.cjs"]
CMD ["serve"]
