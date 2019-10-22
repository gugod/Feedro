FROM perl:5.30

ADD [".", "/app"]
RUN cpanm -q -n --no-man-pages App::cpm &&  cd /src && cpm install -g && cpm install -g . && rm -rf /root/.perl-cpm /root/.cpanm

WORKDIR /app
CMD perl feedro.pl daemon

