FROM ubuntu:24.10

MAINTAINER Jay Luker <jay_luker@harvard.edu>

ARG RUBY_VERSION=3.3.0
ARG POSTGRES_VERSION=16
ARG BUNDLER_VERSION=2.5.10
ARG REVISION=master
ENV RAILS_ENV development
ENV GEM_HOME /opt/canvas/.gems
ENV GEM_PATH ${GEM_HOME}:/opt/canvas/.gem/ruby/${RUBY_VERSION}
ENV DEBIAN_FRONTEND noninteractive

# add nodejs and recommended ruby repos
RUN apt-get update \
    && apt-get install -y autoconf curl curl fontforge g++ git libicu-dev \
    libidn-dev libpq-dev libsqlite3-dev libxml2-dev libxmlsec1-dev \
    libxslt1-dev make postgresql postgresql-contrib redis-server ruby ruby-dev \
    software-properties-common sudo supervisor unzip zlib1g-dev \
    && apt-get clean && rm -Rf /var/cache/apt

RUN curl -sSL -o apache-pulsar-client-dev.deb https://archive.apache.org/dist/pulsar/pulsar-2.6.1/DEB/apache-pulsar-client-dev.deb \
  && curl -sSL -o apache-pulsar-client.deb https://archive.apache.org/dist/pulsar/pulsar-2.6.1/DEB/apache-pulsar-client.deb \
  && dpkg -i apache-pulsar-client.deb \
  && dpkg -i apache-pulsar-client-dev.deb \
  && rm apache-pulsar-client-dev.deb apache-pulsar-client.deb

RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - \
    && echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        nodejs \
        yarn \
        unzip \
        fontforge \
    && apt-get clean && rm -Rf /var/cache/apt

# Set the locale to avoid active_model_serializers bundler install failure
RUN locale-gen en_US.UTF-8
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

RUN groupadd -r canvasuser -g 433 && \
    adduser --uid 431 --system --gid 433 --home /opt/canvas canvasuser && \
    adduser canvasuser sudo && \
    echo '%sudo ALL=(ALL) NOPASSWD:ALL\nDefaults env_keep += "GEM_HOME GEM_PATH RAILS_ENV REVISION LANG LANGUAGE LC_ALL"' >> /etc/sudoers

RUN sudo -u canvasuser mkdir -p $GEM_HOME \
  && sudo -u canvasuser gem install --user-install bundler:${BUNDLER_VERSION} --no-document

COPY --chown=canvasuser assets/dbinit.sh /opt/canvas/dbinit.sh
COPY --chown=canvasuser assets/start.sh /opt/canvas/start.sh
RUN chmod 755 /opt/canvas/*.sh

COPY assets/supervisord.conf /etc/supervisor/supervisord.conf
COPY assets/pg_hba.conf /etc/postgresql/${POSTGRES_VERSION}/main/pg_hba.conf
RUN sed -i "/^#listen_addresses/i listen_addresses='*'" /etc/postgresql/${POSTGRES_VERSION}/main/postgresql.conf

RUN cd /opt/canvas \
    && sudo -u canvasuser git clone https://github.com/instructure/canvas-lms.git --branch $REVISION --single-branch

WORKDIR /opt/canvas/canvas-lms

COPY --chown=canvasuser assets/database.yml config/database.yml
COPY --chown=canvasuser assets/domain.yml config/domain.yml
COPY --chown=canvasuser assets/redis.yml config/redis.yml
COPY --chown=canvasuser assets/cache_store.yml config/cache_store.yml
COPY --chown=canvasuser assets/development-local.rb config/environments/development-local.rb
COPY --chown=canvasuser assets/outgoing_mail.yml config/outgoing_mail.yml
COPY assets/healthcheck.sh /usr/local/bin/healthcheck.sh

RUN for config in amazon_s3 delayed_jobs domain file_store security external_migration \
       ; do cp config/$config.yml.example config/$config.yml \
       ; done

ARG BUNDLE=/opt/canvas/.local/share/gem/ruby/${RUBY_VERSION}/bin/bundle
RUN sudo -u canvasuser ${BUNDLE} config set --local without 'development:test' \
  &&sudo -u canvasuser ${BUNDLE} config set --local without 'mysql' \
  && sudo -u canvasuser ${BUNDLE} install --jobs 8

RUN sudo -u canvasuser yarn install --pure-lockfile && sudo -u canvasuser yarn cache clean
RUN sudo -u canvasuser COMPILE_ASSETS_NPM_INSTALL=0 ${BUNDLE} _${BUNDLER_VERSION}_ exec rake canvas:compile_assets_dev

RUN sudo -u canvasuser mkdir -p log tmp/pids public/assets public/stylesheets/compiled \
    && sudo -u canvasuser touch Gemfile.lock

RUN service postgresql start && sudo -u canvasuser /opt/canvas/dbinit.sh

RUN chown -R canvasuser: /tmp/attachment_fu/

# postgres
EXPOSE 5432
# redis
EXPOSE 6379
# canvas
EXPOSE 3000

HEALTHCHECK --interval=3m --start-period=5m \
   CMD /usr/local/bin/healthcheck.sh

CMD ["/opt/canvas/start.sh"]
