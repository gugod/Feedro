#!/usr/bin/env perl
use v5.18;
use strict;
use warnings;
use Mojolicious::Lite;
use JSON::Feed;
use Path::Tiny qw< path >;

use constant FEEDRO_STORAGE_DIR => $ENV{FEEDRO_STORAGE_DIR} // '';

# Storage
my %feeds;

sub save_feeds {
    return unless FEEDRO_STORAGE_DIR;

    for my $id (keys %feeds) {
        my $str = $feeds{$id}->to_string;
        path(FEEDRO_STORAGE_DIR, "${id}.json")->spew_utf8($str);
    }

    return;
}

sub load_feeds {
    return unless FEEDRO_STORAGE_DIR;
    path(FEEDRO_STORAGE_DIR)->mkpath();
    path(FEEDRO_STORAGE_DIR)->visit(
        sub {
            my ($path) = @_;
            return unless $path =~ /\.json$/;
            my $id = $path->basename('.json');
            my $content = $path->slurp_utf8();
            $feeds{$id} = JSON::Feed->parse( \$content );
        },
        { recurse => 0, follow_symlinks => 0 },
    );
}

# main

put '/feed/:identifier' => sub {
    my ($c) = @_;
    my $id = $c->param('identifier');
    my $feed = $c->req->json;
    $feeds{$id} = JSON::Feed->new(%$feed);

    $c->render( json => { "ok" => \1 });
};

post '/feed/:identifier/items' => sub {
    my ($c) = @_;
    my $id = $c->param('identifier');
    my $item = $c->req->json;

    my $feed = $feeds{$id};
    $feed->add_item(%$item);

    if (@{ $feed->feed->{items} } > 1000) {
        shift @{ $feed->feed->{items} };
    }

    save_feeds();
    
    $c->render( json => { "ok" => \1 });
};

get '/feed/:identifier' => sub {
    my ($c) = @_;
    my $id = $c->param('identifier');
    my $feed = $feeds{$id};
    $c->render( json => $feed->feed );
};

load_feeds();
app->start;
