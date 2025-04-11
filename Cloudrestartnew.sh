#!/bin/bash
# Get public IP and convert HTTPS flag to lowercase
public_ip=$(curl -s http://checkip.amazonaws.com)
use_https=true
SUBDOMAIN=cloudpie.ai
# Determine protocol and host
if [[ "$use_https" == "true" && -n "$SUBDOMAIN" ]]; then
  host_value="$SUBDOMAIN"
  protocol="https"
else
  host_value="$public_ip"
  protocol="http"
fi

echo "Using host: $protocol://$host_value"

# Update Redis Host
sed -i "s/^REDIS_HOST = .*/REDIS_HOST = '${public_ip}'/" /app/superset/superset_config.py

# Update CORS Origins
sed -i '/"origins": \[/d' /app/superset/superset_config.py
sed -i "/CORS_OPTIONS ={/a \ \ \ \ \ \ \ \ \"origins\": [\"${protocol}://${host_value}:3000\"]," /app/superset/superset_config.py

# Wait for MySQL to be ready
while ! mysqladmin ping -h ${public_ip} --silent; do
    echo "Waiting for MySQL to start..."
    sleep 5
done

echo "Starting the CloudPi application"

pm2 delete superset-server
# Stop all PM2 apps
pm2 delete all



# Node.js .env
env_file="/app/backend/.env"

sed -i '/^HTTPS=/d' $env_file
if [[ "$use_https" == "true" ]]; then
  echo "HTTPS=true" >> $env_file
else
  echo "HTTPS=false" >> $env_file
fi

sed -i '/^DB_HOST=/d' $env_file
echo "DB_HOST=$host_value" >> $env_file

sed -i '/^FLASK_API_URL=/d' $env_file
echo "FLASK_API_URL=${protocol}://${host_value}:5005" >> $env_file

sed -i '/^NODE_API_URL=/d' $env_file
echo "NODE_API_URL=${protocol}://${host_value}:5001" >> $env_file

sed -i '/^REACT_APP_ORIGIN_URL=/d' $env_file
if [[ "$use_https" == "true" ]]; then
  echo "REACT_APP_ORIGIN_URL=${protocol}://${host_value}" >> $env_file
else
  echo "REACT_APP_ORIGIN_URL=${protocol}://${host_value}:3000" >> $env_file
fi

sed -i '/^SUPERSET_URL=/d' $env_file
echo "SUPERSET_URL=${protocol}://${host_value}:8088" >> $env_file

sed -i '/^REDIS_HOST=/d' $env_file
echo "REDIS_HOST=${public_ip}" >> $env_file

# Start Node
cd /app/backend
pm2 start ./dist/app.js --name CloudPi-Node -f --wait-ready

# Flask .env
env_file="/app/Flask/pico/.env"

sed -i '/^HTTPS=/d' $env_file
if [[ "$use_https" == "true" ]]; then
  echo "HTTPS=True" >> $env_file
  sed -i '/^NODE_HTTPS=/d' $env_file
  echo "NODE_HTTPS=${use_https}" >> $env_file
fi


sed -i '/^MYSQLALCHEMY_DATABASE_URI=/d' $env_file
echo "MYSQLALCHEMY_DATABASE_URI=mysql+pymysql://admin:AWSGCPPI_2k23@$host_value/pidb" >> $env_file

sed -i '/^DATABASE_URL=/d' $env_file
echo "DATABASE_URL=mysql+pymysql://admin:AWSGCPPI_2k23@$host_value/pidb" >> $env_file

# Start Flask
cd /app/Flask/pico
pm2 start ./dist/app --name "CloudPi-Flask" -f --wait-ready

# React .env
env_file="/app/frontend/build/env.js"
sed -i '/^REACT_APP_API_URL=/d' $env_file
echo "REACT_APP_API_URL=${protocol}://${host_value}:5001/" >> $env_file

sed -i '/^REACT_APP_FLASK_URL=/d' $env_file
echo "REACT_APP_FLASK_URL=${protocol}://${host_value}:5005" >> $env_file

cd /app/frontend
REACT_APP_FLASK_URL="${protocol}://${host_value}:5005" REACT_APP_API_URL="${protocol}://${host_value}:5001/" npx react-inject-env set

cd /app/frontend/build
rm -rf env.js
touch env.js
chmod 777 env.js
echo "document.env = {" > env.js
echo "  REACT_APP_API_URL: '${protocol}://${host_value}:5001/'," >> env.js
echo "  REACT_APP_FLASK_URL: '${protocol}://${host_value}:5005'" >> env.js
echo "};" >> env.js
cd ..
pm2 start http-server --name "CloudPi-FE2.0" -- -p 3000 ./build -f --wait-ready
cd /app/frontend
cp -r /app/frontend/build/assets /usr/share/nginx/html
cp -r /app/frontend/build/env.js /usr/share/nginx/html


# Superset DB connection update

cd /app/superset
source superset_env/bin/activate
pm2 delete superset-server
# Kill process on port 8088 if in use
# Ensure port 8088 is free

if [[ "$use_https" == "true" ]]; then
export SUPERSET_CONFIG_PATH=/app/superset/superset_config.py && . /app/superset/superset_env/bin/activate && pm2 start "gunicorn -w 10 -k gevent --timeout 120 -b 0.0.0.0:8088 --limit-request-line 0 --limit-request-field_size 0 --statsd-host localhost:8125 --certfile /home/ec2-user/certs/cloudpi_certificate.crt --keyfile /home/ec2-user/certs/cloudpi_private.key --ca-certs /home/ec2-user/certs/ca_bundle.crt 'superset.app:create_app()'" --name "superset-server"
#export SUPERSET_CONFIG_PATH=/app/superset/superset_config.py && . /app/superset/superset_env/bin/activate && pm2 start "gunicorn -w 10 -k gevent --timeout 120 -b 0.0.0.0:8088 --limit-request-line 0 --limit-request-field_size 0 --statsd-host localhost:8125 --certfile /home/ec2-user/certs/cloudpi_certificate.crt --keyfile /home/ec2-user/certs/cloudpi_private.key --ca-certs /home/ec2-user/certs/ca_bundle.crt 'superset.app:create_app()'" --name "superset-server" 
else
export SUPERSET_CONFIG_PATH=/app/superset/superset_config.py && . /app/superset/superset_env/bin/activate && pm2 start "gunicorn -w 10 -k gevent --timeout 120 -b 0.0.0.0:8088 'superset.app:create_app()'" --name "superset-server"
#SUPerset_CONFIG=/app/superset/superset_config.py  pm2 start "gunicorn -w 4 -b 0.0.0.0:8088 'superset.app:create_app()'" --name superset-server

fi

# Update existing SUPERTSET_URL line in update_dbconn.py
sed -i "s|^SUPERTSET_URL = .*|SUPERTSET_URL = '${protocol}://${host_value}:8088'|" /app/superset/update_dbconn.py
sed -i "s/TARGET_IP/${host_value}/g" /app/superset/update_dbconn.py
sed -i "s/TARGET_CONN/admin:AWSGCPPI_2k23@${host_value}/g" /app/superset/update_dbconn.py

pm2 restart superset-server

python3 update_dbconn.py
deactivate

# Replace localhost with current host
sed -i "s/localhost/$host_value/g" superset_config.py

# Restart Superset and PM2 apps
echo "Restarting Superset and PM2 apps"
pm2 restart superset-server

pm2 restart all
nginx -t
nginx -s stop
nginx 
nginx -s reload
echo "CloudPi started successfully with $protocol://$host_value"