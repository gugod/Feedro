#!/usr/bin/env perl
use v5.18;
use strict;
use warnings;
use Mojolicious::Lite;
use JSON::Feed;
use Digest::SHA1 qw<sha1_hex>;
use Data::UUID;
use Path::Tiny qw< path >;
use Data::Dumper;

use constant FEEDRO_STORAGE_DIR => $ENV{FEEDRO_STORAGE_DIR} // '';

# Storage
my %feeds;
my %tokens;

sub save_feeds {
    return unless FEEDRO_STORAGE_DIR;

    for my $id ( keys %feeds ) {
        my $str = $feeds{$id}->to_string;
        path( FEEDRO_STORAGE_DIR, "${id}.json" )->spew_utf8($str);
    }

    for my $id ( keys %tokens ) {
        my $str = $tokens{$id};
        path( FEEDRO_STORAGE_DIR, "${id}.token.txt" )->spew_utf8($str);
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


sub sha1_base64 {
    my ($x) = @_;
    my $sha1 = Digest::SHA1->new;
    $sha1->add($x);
    my $b64 = $sha1->b64digest; 
    my $b64uri = $b64 =~ y!+/!-_!r;
    return $b64uri;
}

sub is_prime {
    my $n = $_[0];
    for my $k (2..sqrt($n)) {
        return 0 if $n % $k == 0;
    }
    return 1;
}

sub proof_looks_good {
    my ($title, $description, $t, $p, $sha1) = @_;
    my $now = time();
    return 0 if ($now < $t || $now - $t > 3600 || !is_prime($p));
    my $h = sha1_hex(join "\n", $title, $description, $t, $p);
    return ($h eq $sha1 && substr($h, 0, 4) eq "feed");
}

sub create_feed {
    my $req = $_[0];
    my %feed = %$req;
    my $proof = delete($feed{proof});

    unless (proof_looks_good($feed{title}, $feed{description}, @$proof)) {
        return undef;
    }

    my $ug = Data::UUID->new;
    my $uuid = $ug->create;
    my $id = $ug->to_string($uuid);

    $feeds{$id} = JSON::Feed->new(%feed);
    my $token = $tokens{$id} = sha1_base64( join "\n", time, rand(), $id, @$proof );
    save_feeds();

    return { identifier => $id, token => $token };
}

# main

## API: Feed creation
post '/feed' => sub {
    my ($c) = @_;
    my $res = create_feed($c->req->json);

    if ($res && $res->{identifier} && $res->{token}) {
        $c->render( json => $res );
        return;
    }

    $c->render( json => { error => "Feed creation failed" });
};

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
