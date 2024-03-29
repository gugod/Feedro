#!/usr/bin/env perl
use Mojolicious::Lite;

use Mojo::Collection ();
use Time::Moment ();
use Data::UUID ();
use JSON::Feed 1.000 ();
use XML::FeedPP (); # Implies: XML::FeedPP::RSS, XML::FeedPP::Atom::Atom10;
use Digest::SHA1 qw<sha1_hex>;
use Path::Tiny qw< path >;
use Math::Prime::XS qw< is_prime >;
use Encode qw< encode_utf8 >;

use constant {
    FEEDRO_STORAGE_DIR => $ENV{FEEDRO_STORAGE_DIR} // '/tmp/feedro/',

    ERROR_PROOF_IS_NOT_GOOD => "Proof is not good",
    ERROR_TOKEN_INVALID => "Token is invalid",
    ERROR_FEED_ID_UNKNOWN => "Unknown feed id",
    ERROR_FEED_CREATION_FAIL => "Feed creation failed",
    ERROR_INSUFFICIENT => "Insufficient",
};

sub token_in_request_header {
    my ($c) = @_;
    my $auth = $c->req->headers->header('Authentication') // '';
    if ($auth =~ /\ABearer (.+)\z/) {
        return $1;
    }
    return '';
}

sub save_token {
    my ($id, $token) = @_;
    path( FEEDRO_STORAGE_DIR, "${id}.token.txt" )->spew_utf8($token);
}

sub token_is_valid {
    my ($id, $token) = @_;
    my $stored_token = path( FEEDRO_STORAGE_DIR, "${id}.token.txt" )->slurp_utf8();
    return ($stored_token eq $token);
}

sub feed_exists {
    my ($id) = @_;
    return feed_path_json($id)->exists;
}

sub feed_path_json { my $id = $_[0]; path( FEEDRO_STORAGE_DIR, "${id}.json" ) }
sub feed_path_atom { my $id = $_[0]; path( FEEDRO_STORAGE_DIR, "${id}.atom" ) }
sub feed_path_rss  { my $id = $_[0]; path( FEEDRO_STORAGE_DIR, "${id}.rss"  ) }

sub save_feed {
    my ($id, $feed) = @_;

    feed_path_json($id)->spew_utf8( $feed->to_string );

    my @xml_feeds = (
        [ XML::FeedPP::Atom::Atom10->new(), feed_path_atom($id) ],
        [ XML::FeedPP::RSS->new(), feed_path_rss($id) ],
    );

    for my $el (@xml_feeds) {
        my ($xml_feed, $path) = @$el;
        load_xml_feed_from_json_feed( $xml_feed, $feed );
        $path->spew( $xml_feed->to_string );
    }

    return;
}

sub load_tokens {
    path(FEEDRO_STORAGE_DIR)->mkpath();
}

sub load_feed {
    my ($id) = @_;
    return JSON::Feed->from_string( path(FEEDRO_STORAGE_DIR)->child($id . '.json')->slurp_utf8() );
}

sub sha1_base64 {
    my ($x) = @_;
    my $sha1 = Digest::SHA1->new;
    $sha1->add($x);
    my $b64 = $sha1->b64digest;
    my $b64uri = $b64 =~ y{+/}{-_}r;
    return $b64uri;
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
        return unless ($id =~ /\A[A-Za-z0-9][A-Za-z0-9\-]{14,}[A-Za-z0-9]\z/ && feed_exists($id) );
    } else {
        $id = Data::UUID->new->create_str();
        while ( feed_exists($id) ) {
            $id = Data::UUID->new->create_str();
        }
    }

    my $feed = JSON::Feed->new(
        title => $req->{title},
        description => $req->{description}
    );
    my $token = sha1_base64( join "\n", time, rand(), $id );
    save_feed($id, $feed);
    save_token($id, $token);

    return { identifier => $id, token => $token };
}

sub append_item {
    my ($feed_id, $item, $token) = @_;

    return { error => ERROR_FEED_ID_UNKNOWN } unless feed_exists($feed_id);
    return { error => ERROR_TOKEN_INVALID } unless token_is_valid($feed_id, $token);
    return { error => ERROR_INSUFFICIENT } unless $item->{content_text} || $item->{title};

    my $feed = load_feed( $feed_id );

    my $items = Mojo::Collection->new(@{ $feed->get("items") });
    if ( $item->{id} && $items->first(sub { $_->{id} eq $item->{id} }) ) {
        return {};
    } elsif ( $item->{url} && $items->first(sub { $_->{url} && ($_->{url} eq $item->{url}) }) ) {
        return {};
    } else {
        $item->{id} = Data::UUID->new->create_str();
    }

    $item->{date_published} //= Time::Moment->now->strftime('%Y-%m-%dT%H:%M:%S%f%Z');

    $feed->add_item(%$item);
    my $item_count = @{ $feed->feed->{items} };
    if ( $item_count > 100 ) {
        splice @{ $feed->feed->{items} }, 0, $item_count - 100;
    }

    save_feed($feed_id, $feed);
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
            pubDate => $item->{date_published},
            ($item->{author} ? (
                author => $item->{author},
            ):()),
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
    my $_feed = $c->req->json;
    my $feed = JSON::Feed->new(%$_feed);

    save_feed($id, $feed);

    $c->render( json => { "ok" => \1 } );
};

post '/feed/:identifier/items' => sub {
    my ($c)  = @_;
    my $feed_id   = $c->param('identifier');

    unless ( feed_exists($feed_id) ) {
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

        if ( my $y = $c->param('author.name') ) {
            $item->{"author"} = { "name" => $y };
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

    unless (feed_exists($id)) {
        $c->render( status => 404, json => { error => ERROR_FEED_ID_UNKNOWN });
        return;
    }

    my $token = token_in_request_header($c);

    unless ( token_is_valid($id, $token) ) {
        $c->render( status => 401, json => { error => ERROR_TOKEN_INVALID });
        return;
    }

    my $feed = load_feed($id);

    # XXX: Leaky abstraction.
    $feed->feed->{items} = [];

    save_feed($id, $feed);

    $c->render( json => { ok => \1 });
};

get '/feed/:identifier' => [ "format" => ["json", "atom", "rss"] ] => sub {
    my ($c)  = @_;
    my $id   = $c->param('identifier');

    my ($feed, $feed_file);

    unless ( feed_exists($id) ) {
        $c->render( status => 404, json => { error => ERROR_FEED_ID_UNKNOWN } );
        return;
    }

    $c->respond_to(
        json => sub {
            $c->reply->file( feed_path_json($id) );
        },
        atom => sub {
            $c->reply->file( feed_path_atom($id) );
        },
        rss => sub {
            $c->reply->file( feed_path_rss($id) );
        },
        any  => { data => '', status => 404 },
    );
};

load_tokens();
app->start;
