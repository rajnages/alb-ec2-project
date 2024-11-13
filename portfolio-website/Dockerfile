# Use Node.js LTS (Long Term Support) version
FROM node:18-alpine

# Create app directory
WORKDIR /usr/src/app

# Install app dependencies
# Copy package.json and package-lock.json first for better caching
COPY package*.json ./

# Install dependencies
RUN npm install

# Copy app source code
COPY . .

# Create necessary directories if they don't exist
#RUN mkdir -p public/images

# Expose the port the app runs on
EXPOSE 3000

# Command to run the application
CMD ["npm", "start"]