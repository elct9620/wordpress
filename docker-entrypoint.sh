#!/bin/bash
set -e

	if [ -n "$MYSQL_PORT_3306_TCP" ]; then
		if [ -z "$WORDPRESS_DB_HOST" ]; then
			WORDPRESS_DB_HOST='mysql'
		else
			echo >&2 'warning: both WORDPRESS_DB_HOST and MYSQL_PORT_3306_TCP found'
			echo >&2 "  Connecting to WORDPRESS_DB_HOST ($WORDPRESS_DB_HOST)"
			echo >&2 '  instead of the linked mysql container'
		fi
	fi

	if [ -z "$WORDPRESS_DB_HOST" ]; then
		echo >&2 'error: missing WORDPRESS_DB_HOST and MYSQL_PORT_3306_TCP environment variables'
		echo >&2 '  Did you forget to --link some_mysql_container:mysql or set an external db'
		echo >&2 '  with -e WORDPRESS_DB_HOST=hostname:port?'
		exit 1
	fi

	# if we're linked to MySQL and thus have credentials already, let's use them
	: ${WORDPRESS_DB_USER:=${MYSQL_ENV_MYSQL_USER:-root}}
	if [ "$WORDPRESS_DB_USER" = 'root' ]; then
		: ${WORDPRESS_DB_PASSWORD:=$MYSQL_ENV_MYSQL_ROOT_PASSWORD}
	fi
	: ${WORDPRESS_DB_PASSWORD:=$MYSQL_ENV_MYSQL_PASSWORD}
	: ${WORDPRESS_DB_NAME:=${MYSQL_ENV_MYSQL_DATABASE:-wordpress}}

	if [ -z "$WORDPRESS_DB_PASSWORD" ]; then
		echo >&2 'error: missing required WORDPRESS_DB_PASSWORD environment variable'
		echo >&2 '  Did you forget to -e WORDPRESS_DB_PASSWORD=... ?'
		echo >&2
		echo >&2 '  (Also of interest might be WORDPRESS_DB_USER and WORDPRESS_DB_NAME.)'
		exit 1
	fi

	if ! [ -e index.php -a -e wp-includes/version.php ]; then
		echo >&2 "WordPress not found in $(pwd) - copying now..."
		if [ "$(ls -A)" ]; then
			echo >&2 "WARNING: $(pwd) is not empty - press Ctrl+C now if this is an error!"
			( set -x; ls -A; sleep 10 )
		fi
		tar cf - -C /usr/src/wordpress . | tar xf -
		echo >&2 "Complete! WordPress has been successfully copied to $(pwd)"
	fi

	# TODO handle WordPress upgrades magically in the same way, but only if wp-includes/version.php's $wp_version is less than /usr/src/wordpress/wp-includes/version.php's $wp_version

	# version 4.4.1 decided to switch to windows line endings, that breaks our seds and awks
	# https://github.com/docker-library/wordpress/issues/116
	# https://github.com/WordPress/WordPress/commit/1acedc542fba2482bab88ec70d4bea4b997a92e4
	sed -ri 's/\r\n|\r/\n/g' wp-config*

	if [ ! -e wp-config.php ]; then
    echo "Setup wp-config.php"
		awk '/^\/\*.*stop editing.*\*\/$/ && c == 0 { c = 1; system("cat") } { print }' wp-config-sample.php > wp-config.php <<'EOPHP'
// If we're behind a proxy server and using HTTPS, we need to alert Wordpress of that fact
// see also http://codex.wordpress.org/Administration_Over_SSL#Using_a_Reverse_Proxy
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
	$_SERVER['HTTPS'] = 'on';
}
EOPHP
		chown www-data:www-data wp-config.php
	fi

	# see http://stackoverflow.com/a/2705678/433558
	sed_escape_lhs() {
		echo "$@" | sed 's/[]\/$*.^|[]/\\&/g'
	}
	sed_escape_rhs() {
		echo "$@" | sed 's/[\/&]/\\&/g'
	}
	php_escape() {
		php -r 'var_export(('$2') $argv[1]);' "$1"
	}
	set_config() {
		key="$1"
		value="$2"
		var_type="${3:-string}"
		start="['\"]$(sed_escape_lhs "$key")['\"]\s*,"
		end="\);"
		if [ "${key:0:1}" = '$' ]; then
			start="^(\s*)$(sed_escape_lhs "$key")\s*="
			end=";"
		fi
		sed -ri "s/($start\s*).*($end)$/\1$(sed_escape_rhs "$(php_escape "$value" "$var_type")")\2/" wp-config.php
	}

  set_php_config() {
    # No default php config file, direct create new file and add config
    CONFIG_FILE="/usr/local/etc/php/php.ini"
    [[ ! -f ${CONFIG_FILE} ]] && touch ${CONFIG_FILE}

    key="$1"
    value="$2"

    echo "$key=$value" >> ${CONFIG_FILE}
  }

  set_smtp_config() {
    key=$1
    value=$2

    sed -ri "s/#{0,1}$key\s+.*$/$key $value/g" ${CONFIG_FILE}
  }

  setup_smtp() {
    LOG_FILE='/var/log/mail.log'
    CONFIG_FILE='/etc/msmtprc'

    touch ${LOG_FILE}
    chown www-data:www-data ${LOG_FILE}
    chown www-data:www-data ${CONFIG_FILE}
    chmod 0600 ${CONFIG_FILE}

    if [[ -n ${SMTP_FROM} ]]; then
      set_smtp_config 'from' ${SMTP_FROM}
    fi
    if [[ -n ${SMTP_HOST} ]]; then
      set_smtp_config 'host' ${SMTP_HOST}
    fi
    if [[ -n ${SMTP_PORT} ]]; then
      set_smtp_config 'port' ${SMTP_PORT}
    fi
    if [[ -n ${SMTP_TLS} ]]; then
      set_smtp_config 'tls' ${SMTP_TLS}
    fi
    if [[ -n ${SMTP_AUTH} ]]; then
      set_smtp_config 'auth' ${SMTP_AUTH}
    fi
    if [[ -n ${SMTP_USER} ]]; then
      set_smtp_config 'user' ${SMTP_USER}
      set_smtp_config 'auth' 'on' # Force enable auth
    fi
    if [[ -n ${SMTP_PASSWORD} ]]; then
      set_smtp_config 'password' ${SMTP_PASSWORD}
    fi
  }

  setup_smtp

  set_php_config 'display_errors' 'Off'
  set_php_config 'log_errors' 'On'
  set_php_config 'error_log' '/dev/stderr'
  set_php_config 'upload_max_filesize' '10M'
  [[ -n ${SMTP_HOST} ]] && set_php_config 'sendmail_path' '/usr/bin/msmtp -C /etc/msmtprc -t'

	set_config 'DB_HOST' "$WORDPRESS_DB_HOST"
	set_config 'DB_USER' "$WORDPRESS_DB_USER"
	set_config 'DB_PASSWORD' "$WORDPRESS_DB_PASSWORD"
	set_config 'DB_NAME' "$WORDPRESS_DB_NAME"

	# allow any of these "Authentication Unique Keys and Salts." to be specified via
	# environment variables with a "WORDPRESS_" prefix (ie, "WORDPRESS_AUTH_KEY")
	UNIQUES=(
		AUTH_KEY
		SECURE_AUTH_KEY
		LOGGED_IN_KEY
		NONCE_KEY
		AUTH_SALT
		SECURE_AUTH_SALT
		LOGGED_IN_SALT
		NONCE_SALT
	)
	for unique in "${UNIQUES[@]}"; do
		eval unique_value=\$WORDPRESS_$unique
		if [ "$unique_value" ]; then
			set_config "$unique" "$unique_value"
		else
			# if not specified, let's generate a random value
			current_set="$(sed -rn "s/define\((([\'\"])$unique['\"]\s*,\s*)(['\"])(.*)['\"]\);/\4/p" wp-config.php)"
			if [ "$current_set" = 'put your unique phrase here' ]; then
				set_config "$unique" "$(strings /dev/urandom | grep -o '[[:print:]]' | head -n 64 | tr -d '\n')"
			fi
		fi
	done

	if [ "$WORDPRESS_TABLE_PREFIX" ]; then
		set_config '$table_prefix' "$WORDPRESS_TABLE_PREFIX"
	fi

	if [ "$WORDPRESS_DEBUG" ]; then
		set_config 'WP_DEBUG' 1 boolean
	fi

	TERM=dumb php -- "$WORDPRESS_DB_HOST" "$WORDPRESS_DB_USER" "$WORDPRESS_DB_PASSWORD" "$WORDPRESS_DB_NAME" <<'EOPHP'
<?php
// database might not exist, so let's try creating it (just to be safe)
$stderr = fopen('php://stderr', 'w');
list($host, $port) = explode(':', $argv[1], 2);
$maxTries = 10;
do {
	$mysql = new mysqli($host, $argv[2], $argv[3], '', (int)$port);
	if ($mysql->connect_error) {
		fwrite($stderr, "\n" . 'MySQL Connection Error: (' . $mysql->connect_errno . ') ' . $mysql->connect_error . "\n");
		--$maxTries;
		if ($maxTries <= 0) {
			exit(1);
		}
		sleep(3);
	}
} while ($mysql->connect_error);
if (!$mysql->query('CREATE DATABASE IF NOT EXISTS `' . $mysql->real_escape_string($argv[4]) . '`')) {
	fwrite($stderr, "\n" . 'MySQL "CREATE DATABASE" Error: ' . $mysql->error . "\n");
	$mysql->close();
	exit(1);
}
$mysql->close();
EOPHP

exec "$@"
