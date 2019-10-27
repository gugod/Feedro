FROM perl:5.30
RUN cpanm -q -n --no-man-pages App::cpm

COPY [".", "/app"]
WORKDIR /app

RUN cpm install -g
RUN rm -rf /root/.perl-cpm /root/.cpanm

EXPOSE 3000
CMD perl feedro.pl daemon
