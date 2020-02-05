#!/usr/bin/env perl
use Mojolicious::Lite;

use Mojo::Collection;
use JSON::Feed;
use XML::FeedPP; # Implies: XML::FeedPP::RSS, XML::FeedPP::Atom::Atom10;
use Digest::SHA1 qw<sha1_hex>;
use Data::UUID;
use Path::Tiny qw< path >;

use constant {
    FEEDRO_STORAGE_DIR => $ENV{FEEDRO_STORAGE_DIR} // '/tmp/feedro/',

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
    for my $id ( keys %tokens ) {
        my $str = $tokens{$id};
        path( FEEDRO_STORAGE_DIR, "${id}.token.txt" )->spew_utf8($str);
    }

    return;
}

sub save_feeds {
    my ($feed_id) = @_;

    for my $id ( keys %feeds ) {
        my $feed = $feeds{$id}{__json_feed_obj} or next;

        my $str = $feed->to_string;
        path( FEEDRO_STORAGE_DIR, "${id}.json" )->spew_utf8($str);

        my @xml_feeds = (
            [ XML::FeedPP::Atom::Atom10->new(), path( FEEDRO_STORAGE_DIR, "${id}.atom" ) ],
            [ XML::FeedPP::RSS->new(), path( FEEDRO_STORAGE_DIR, "${id}.rss" ) ],
        );

        for my $el (@xml_feeds) {
            my ($xml_feed, $path) = @$el;
            load_xml_feed_from_json_feed( $xml_feed, $feed );
            $path->spew( $xml_feed->to_string );
        }

        delete $feeds{$id}{__json_feed_obj};
    }

    return;
}

sub load_tokens {
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
    path(FEEDRO_STORAGE_DIR)->mkpath();
    path(FEEDRO_STORAGE_DIR)->visit(
        sub {
            my ($path) = @_;
            return unless $path =~ /\.(atom|rss|json)$/;
            my $fmt = $1;
            my $id = $path->basename(".${fmt}");
            $feeds{$id}{$fmt}{path} = $path;
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
    my $id;

    if ($id = $req->{id}) {
        return unless ( ($id =~ /\A[A-Za-z0-9][A-Za-z0-9\-]{14,}[A-Za-z0-9]\z/) && (not exists $feeds{$id}) );
    } else {
        $id = Data::UUID->new->create_str();
        while (exists $feeds{$id}) {
            $id = Data::UUID->new->create_str();
        }
    }

    $feeds{$id}{__json_feed_obj} = JSON::Feed->new(
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

    return { error => ERROR_FEED_ID_UNKNOWN } unless $feeds{$feed_id};
    return { error => ERROR_TOKEN_INVALID } if $tokens{$feed_id} && $token ne $tokens{$feed_id};
    return { error => ERROR_INSUFFICIENT } unless $item->{content_text} || $item->{title};

    my $feed = $feeds{$feed_id}{__json_feed_obj} = JSON::Feed->parse( "". $feeds{$feed_id}{json}{path} );

    my $items = Mojo::Collection->new(@{ $feed->feed->{items} });
    if ( $item->{id} && $items->first(sub { $_->{id} eq $item->{id} }) ) {
        return {};
    } elsif ( $item->{url} && $items->first(sub { $_->{url} eq $item->{url} }) ) {
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
    $feeds{$id}{__json_feed_obj} = JSON::Feed->new(%$feed);
    save_feeds();

    $c->render( json => { "ok" => \1 } );
};

post '/feed/:identifier/items' => sub {
    my ($c)  = @_;
    my $feed_id   = $c->param('identifier');

    unless ($feeds{$feed_id}) {
        $c->render( status => 404, json => { error => ERROR_FEED_ID_UNKNOWN });
        return;
    }

    my $item = $c->req->json;
    if (!$item) {
        $item = {};
        for my $x (qw< id title url content_text >) {
            if (my $y = $c->param($x)) {
                if ( ref($y) ) {
                    $item->{'content_text'} = $y->slurp;
                } else {
                    $item->{$x} = $y;
                }
            }
        }
    }

    my $token = token_in_request_header($c);
    my $result = append_item( $feed_id, $item, $token );
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

    $c->respond_to(
        json => sub {
            $c->reply->file( $feeds{$id}{json}{path} );
        },
        atom => sub {
            $c->reply->file( $feeds{$id}{atom}{path} );
        },
        rss => sub {
            $c->reply->file( $feeds{$id}{rss}{path} );
        },
        any  => { data => '', status => 404 },
    );
};

load_tokens();
load_feeds();
app->start;
