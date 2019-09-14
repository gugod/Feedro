#!/usr/bin/env perl
use v5.18;
use strict;
use warnings;
use Mojolicious::Lite;
use JSON::Feed;
use Data::UUID;
use Path::Tiny qw< path >;

use constant FEEDRO_STORAGE_DIR => $ENV{FEEDRO_STORAGE_DIR} // '';

# Storage
my %feeds;

sub save_feeds {
    return unless FEEDRO_STORAGE_DIR;

    for my $id ( keys %feeds ) {
        my $str = $feeds{$id}->to_string;
        path( FEEDRO_STORAGE_DIR, "${id}.json" )->spew_utf8($str);
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
            my $id      = $path->basename('.json');
            my $content = $path->slurp();
            $feeds{$id} = JSON::Feed->parse( \$content );
        },
        { recurse => 0, follow_symlinks => 0 },
    );
}

# main

put '/feed/:identifier' => sub {
    my ($c)  = @_;
    my $id   = $c->param('identifier');
    my $feed = $c->req->json;
    $feeds{$id} = JSON::Feed->new(%$feed);
    save_feeds();

    $c->render( json => { "ok" => \1 } );
};

post '/feed/:identifier/items' => sub {
    my ($c)  = @_;
    my $id   = $c->param('identifier');

    my $feed = $feeds{$id};
    unless ($feed) {
        $c->res->code(404);
        $c->render(json => { ok => \0, errors => [ "Feed '$id' is unknown." ] });
        return;
    }

    my $item = $c->req->json;

    if (!$item) {
        $item = {};
        for my $x (qw< id title content_text url >) {
            if (my $y = $c->param($x)) {
                $item->{$x} = $y;
            }
        }
    }

    $item->{id} //= Data::UUID->new->create_str();
    $item->{content_text} //= '';
    $item->{title} //= 'Meaningless Title';

    $feed->add_item(%$item);

    if ( @{ $feed->feed->{items} } > 1000 ) {
        shift @{ $feed->feed->{items} };
    }

    save_feeds();

    $c->render( json => { "ok" => \1 } );
};

get '/feed/:identifier' => sub {
    my ($c)  = @_;
    my $id   = $c->param('identifier');
    my $feed = $feeds{$id};
    unless ($feed) {
        $c->render( data => '', status => 404 );
        return;
    }

    $c->respond_to(
        json => sub { $c->render( text => $feed->to_string ) },
        any  => { data => '', status => 404 },
    );
};

load_feeds();
app->start;
