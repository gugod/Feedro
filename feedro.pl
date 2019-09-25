#!/usr/bin/env perl
use v5.18;
use strict;
use warnings;
use Mojolicious::Lite;
use Mojo::Collection;
use JSON::Feed;
use XML::FeedPP; # Implies: XML::FeedPP::RSS, XML::FeedPP::Atom::Atom10;
use Digest::SHA1 qw<sha1_hex>;
use Data::UUID;
use Path::Tiny qw< path >;

use constant {
    FEEDRO_STORAGE_DIR => $ENV{FEEDRO_STORAGE_DIR} // '',

    ERROR_PROOF_IS_NOT_GOOD => "Proof is not good",
    ERROR_TOKEN_INVALID => "Token is invalid",
    ERROR_FEED_ID_UNKNOWN => "Unknown feed id",
    ERROR_FEED_CREATION_FAIL => "Feed creation failed",
    ERROR_INSUFFICIENT => "Insufficient",
};

# Storage
my %feeds;
my %tokens;

sub token_in_request_header {
    my ($c) = @_;
    my $auth = $c->req->headers->header('Authentication') // '';
    if ($auth =~ /\ABearer (.+)\z/) {
        return $1;
    }
    return '';
}

sub save_tokens {
    return unless FEEDRO_STORAGE_DIR;

    for my $id ( keys %tokens ) {
        my $str = $tokens{$id};
        path( FEEDRO_STORAGE_DIR, "${id}.token.txt" )->spew_utf8($str);
    }

    return;
}

sub save_feeds {
    return unless FEEDRO_STORAGE_DIR;

    for my $id ( keys %feeds ) {
        my $str = $feeds{$id}->to_string;
        path( FEEDRO_STORAGE_DIR, "${id}.json" )->spew_utf8($str);
    }

    return;
}

sub load_tokens {
    return unless FEEDRO_STORAGE_DIR;
    path(FEEDRO_STORAGE_DIR)->mkpath();
    path(FEEDRO_STORAGE_DIR)->visit(
        sub {
            my ($path) = @_;
            return unless $path =~ /\.token.txt$/;
            my $id       = $path->basename('.token.txt');
            $tokens{$id} = $path->slurp();
        },
        { recurse => 0, follow_symlinks => 0 },
    );
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
    my $b64uri = $b64 =~ y{+/}{-_}r;
    return $b64uri;
}

sub is_prime {
    my $n = $_[0];
    for my $k (2..sqrt($n)) {
        return 0 if $n % $k == 0;
    }
    return 1;
}

sub encode_utf8 {
    my $s = $_[0] . "";
    utf8::encode($s);
    return $s;
}

sub proof_looks_ok {
    my ($req) = @_;

    my $title       = $req->{title};
    my $description = $req->{description};
    my $t           = $req->{proof}[0];
    my $p           = $req->{proof}[1];
    my $sha1        = $req->{proof}[2];

    my $now = time();
    return 0 if ($now < $t || $now - $t > 3600 || !is_prime($p));
    
    my $h = sha1_hex(encode_utf8(join "\n", $title, $description, $t, $p));
    return ($h eq $sha1 && substr($h, 0, 4) eq "feed");
}

sub create_feed {
    my $req = $_[0];
    my $id = Data::UUID->new->create_str();

    $feeds{$id} = JSON::Feed->new(
        title => $req->{title},
        description => $req->{description}
    );
    my $token = $tokens{$id} = sha1_base64( join "\n", time, rand(), $id );
    save_feeds();
    save_tokens();

    return { identifier => $id, token => $token };
}

sub append_item {
    my ($feed_id, $item, $token) = @_;
    my $feed = $feeds{$feed_id};
    return { error => ERROR_FEED_ID_UNKNOWN } unless $feed;
    return { error => ERROR_TOKEN_INVALID } if $tokens{$feed_id} && $token ne $tokens{$feed_id};
    return { error => ERROR_INSUFFICIENT } unless $item->{content_text} || $item->{title};

    if ( $item->{id} && Mojo::Collection->new(@{ $feed->feed->{items} })->first(sub { $_->{id} eq $item->{id} }) ) {
        return {};
    } else {
        $item->{id} = Data::UUID->new->create_str();
    }

    $feed->add_item(%$item);
    if ( @{ $feed->feed->{items} } > 1000 ) {
        shift @{ $feed->feed->{items} };
    }

    save_feeds();
    return {};
}

sub load_xml_feed_from_json_feed {
    my ($xml_feed, $json_feed) = @_;

    $xml_feed->title( $json_feed->get('title') );
    $xml_feed->description( $json_feed->get('description') );

    # XXX: Leaky abstraction.
    for my $item (@{ $json_feed->get('items') }) {
        $xml_feed->add_item(
            id => $item->{id},
            link => $item->{url},
            title => $item->{title},
            description => ($item->{content_html} // $item->{content_text}),
        );
    }
    return;
}

# Actions

## API: Feed creation
post '/feed' => sub {
    my ($c) = @_;

    my $req = $c->req->json;

    unless (proof_looks_ok( $req )) {
        $c->render( status => 400, json => { error => ERROR_PROOF_IS_NOT_GOOD });
        return;
    }

    my $res = create_feed($req);

    if (!$res || !$res->{identifier} ||! $res->{token}) {
        $c->render( status => 400, json => { error => ERROR_FEED_CREATION_FAIL });
        return;
    }

    $c->render( json => $res );
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
        $c->render( status => 404, json => { error => ERROR_FEED_ID_UNKNOWN });
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

    my $token = token_in_request_header($c);
    my $result = append_item( $id, $item, $token );
    if ($result->{error}) {
        my $code = ($result->{error} eq ERROR_TOKEN_INVALID) ? 401 : 400;
        $c->render( status => $code, json => $result );
        return;
    }
    $c->render( json => { "ok" => \1 } );
};

del '/feed/:identifier/items' => sub {
    my ($c) = @_;
    my $id   = $c->param('identifier');

    unless ($feeds{$id}) {
        $c->render( status => 404, json => { error => ERROR_FEED_ID_UNKNOWN });
        return;
    }

    my $token = token_in_request_header($c);
    unless ($tokens{$id} eq $token) {
        $c->render( status => 401, json => { error => ERROR_TOKEN_INVALID });
        return;
    }

    # XXX: Leaky abstraction.
    $feeds{$id}->feed->{items} = [];
    save_feeds();

    $c->render( json => { ok => \1 });
};

get '/feed/:identifier' => sub {
    my ($c)  = @_;
    my $id   = $c->param('identifier');

    my ($feed, $feed_file);

    unless ($feed = $feeds{$id}) {
        $c->render( status => 404, json => { error => ERROR_FEED_ID_UNKNOWN } );
        return;
    }

    if (FEEDRO_STORAGE_DIR) {
        $feed_file = path( FEEDRO_STORAGE_DIR, "${id}.json" );
        unless ( $feed_file->is_file ) {
            $c->render( status => 404, json => { error => ERROR_FEED_ID_UNKNOWN } );
            return;
        }
    }

    $c->respond_to(
        json => sub {
            if ($feed_file) {
                $c->reply->file( $feed_file );
            } else {
                $c->render( text => $feed->to_string );
            }
        },
        atom => sub {
            my $xml_feed = XML::FeedPP::Atom::Atom10->new;
            load_xml_feed_from_json_feed( $xml_feed, $feed );
            $c->render( text => $xml_feed->to_string );
        },
        rss => sub {
            my $xml_feed = XML::FeedPP::RSS->new;
            load_xml_feed_from_json_feed( $xml_feed, $feed );
            $c->render( text => $xml_feed->to_string );
        },
        any  => { data => '', status => 404 },
    );
};

load_tokens();
load_feeds();
app->start;
