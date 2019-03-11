#!/usr/bin/env perl
use v5.18;
use strict;
use warnings;
use Mojolicious::Lite;
use JSON::Feed;

# Storage
my %feeds;

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
    $c->render( json => { "ok" => \1 });
};

get '/feed/:identifier' => sub {
    my ($c) = @_;
    my $id = $c->param('identifier');
    my $feed = $feeds{$id};
    $c->render( json => $feed->feed );
};


app->start;
