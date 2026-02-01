FROM nginx:alpine

# Copy static content
COPY index.html /usr/share/nginx/html/index.html

# Expose port 80
EXPOSE 80

# nginx runs in foreground by default
CMD ["nginx", "-g", "daemon off;"]
