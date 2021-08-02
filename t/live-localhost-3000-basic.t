#!/usr/bin/env perl
use v5.18;
use Test2::V0;

use Mojo::UserAgent;
use List::Util qw<first>;
use Data::Dumper qw<Dumper>;
use Digest::SHA1 qw(sha1_hex);
use JSON qw(decode_json);
use Math::Prime::XS qw(is_prime);

use constant FEEDRO => "http://localhost:3000";

sub next_prime {
    my $n = $_[0] + 1;
    $n++ while ! is_prime($n);
    return $n;
}

sub proof {
    my ($title, $description) = @_;

    my $t = time();
    my $prime = 2;
    my $h = sha1_hex(join "\n", $title, $description, $t, $prime);
    while ( substr($h,0,4) ne "feed" ) {
        $prime = next_prime($prime);
        $h = sha1_hex(join "\n", $title, $description, $t, $prime);
    }
    return [ $t, $prime, $h ];
}

sub get_new_unique_url {
    state $n = 1;
    $n = next_prime($n);
    return "http://example.com/prime/$n";
}

sub test_successful_creation {
    my $feed;
    subtest "Attempt to create a feed, expect succesful response" => sub {
        my $ua = Mojo::UserAgent->new();
        my $title = "Food";
        my $description = "A feed about food";
        my $tx = $ua->post(
            FEEDRO . "/feed/",
            json => {
                title => $title,
                description => $description,
                proof => proof( $title, $description ),
            }
        );
        my $res = $tx->result;
        $feed = $res->json;
        is $res->code, "200", "A successful code";
        is $feed, hash {
            field "identifier" => D();
            field "token" => D();
        }, "The structure of successful response";
    };
    return $feed;
}

sub test_failure_creation {
    subtest "Attempt to create feed with invalid proof, expect failure response", sub {
        my $ua = Mojo::UserAgent->new();
        my $tx = $ua->post(
            FEEDRO . "/feed/",
            json => {
                title => "Drink",
                description => "Feed about drinks.",
                proof => proof("XXX" , "YYY"), # Invalid proof
            }
        );
        my $res = $tx->result;
        my $feed = $res->json;
        is $res->code, "400";
        is $feed, hash {
            field error => D();
        };
    };
}

sub test_item_creation {
    my $feed = test_successful_creation();
    my ($id, $token) = ($feed->{"identifier"}, $feed->{"token"});
    my $feed_url = FEEDRO . "/feed/${id}.json";
    my $feedro_items_url = FEEDRO . "/feed/${id}/items";

    my $ua = Mojo::UserAgent->new();
    for my $i (1..30) {
        my $tx = $ua->post(
            $feedro_items_url,
            { Authentication => "Bearer $token" },
            json => {
                title => "Some random stuff",
                content_text => "XXX . $$ . ". localtime(),
                url => get_new_unique_url(),
            }
        );
        is $tx->result->code, "200";
    }

    subtest "Without tokens, expect failures" => sub {
        my $tx = $ua->post(
            $feedro_items_url,
            json => {
                title => "Some random stuff",
                content_text => "XXX",
                url => get_new_unique_url(),
            }
        );
        is $tx->result->code, "401",
    };

    subtest "With the correct token, expect successes" => sub {
        my $tx = $ua->post(
            $feedro_items_url,
            { Authentication => "Bearer $token" },
            json => {
                title => "Some random stuff",
                content_text => "XXX",
                url => get_new_unique_url(),
            }
        );
        is $tx->result->code, "200";
    };

    subtest "With author, expect successes" => sub {
        my $url = get_new_unique_url();
        my $author_name = "Mr. " . next_prime(time);

        my $tx = $ua->post(
            $feedro_items_url,
            { Authentication => "Bearer $token" },
            json => {
                title => "Some random stuff. +author.name",
                content_text => "XXX",
                url => $url,
                author => {
                    "name" => $author_name,
                }
            }
        );
        is $tx->result->code, "200";

        my $res = $ua->get($feed_url)->result;

        is $res->code, "200";

        my $item = first { $_->{url} eq $url } @{$res->json->{"items"}};

        is $item, hash {
            field "author" => hash {
                field "name" => $author_name;
                end();
            };
            etc();
        };
    };

    subtest "post with form" => sub {
        my $url = get_new_unique_url();
        my $author_name = "Mr. " . next_prime(time);
        my $tx = $ua->post(
            $feedro_items_url,
            { Authentication => "Bearer $token" },
            form => {
                "title" => "Some random stuff. +author.name",
                "content_text" => "XXX",
                "url" => $url,
                "author.name" => $author_name,
            }
        );
        is $tx->result->code, "200";

        my $data = $ua->get($feed_url)->result->json;
        my $item = first { $_->{url} eq $url } @{$data->{items}};

        is $item, hash {
            field "author" => hash {
                field "name" => $author_name;
                end();
            };
            etc();
        };
    };

    return $feed;
}

sub test_item_deletion {
    my $feed = test_item_creation();

    my ($id, $token) = ($feed->{"identifier"}, $feed->{"token"});
    my $feedro_items_url = FEEDRO . "/feed/${id}/items";
    my $ua = Mojo::UserAgent->new();

    subtest "Delete all items from the feed" => sub {
        subtest "No token, expecting failures." => sub {
            my $tx = $ua->delete($feedro_items_url);
            is $tx->res->code, 401;
            is $tx->res->json, {
                error => D(),
            };
        };

        subtest "Correct token, expecting successful." => sub {
            my $tx = $ua->delete(
                $feedro_items_url,
                { Authentication => "Bearer $token" }
            );
            is $tx->res->code, 200;
            is $tx->res->json, hash {
                field error => DNE();
                field ok => T();
            };
        };
    };
}

test_item_creation;
test_failure_creation;
test_item_deletion;

done_testing;
