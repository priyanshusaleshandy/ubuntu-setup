# Dockerfile for IT Billing Console
FROM node:20-alpine

# Set working directory
WORKDIR /app

# Copy package files and install dependencies
COPY package*.json ./
RUN npm install --production

# Copy application files
COPY . .

# Expose server port
EXPOSE 3000

# alpine ships no timezone database, so a TZ env var alone does nothing.
RUN apk add --no-cache tzdata

# Environment defaults
ENV PORT=3000
ENV NODE_ENV=production
ENV TZ=Asia/Kolkata

# Start Node.js server
CMD ["node", "server.js"]
