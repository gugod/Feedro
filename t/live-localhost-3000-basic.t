#!/usr/bin/env perl
use v5.18;
use Test2::V0;

use Mojo::UserAgent;
use Data::Dumper qw<Dumper>;
use Digest::SHA1 qw(sha1_hex);
use constant FEEDRO => "http://localhost:3000";

sub is_prime {
    my $n = $_[0];
    for my $k (2..sqrt($n)) {
        return 0 if $n % $k == 0;
    }
    return 1;
}

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
            field identifier => D();
            field token => D();
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

sub test_item_crud {
    my $ua = Mojo::UserAgent->new();
    my $feed = test_successful_creation();

    subtest "Attempt to add an item into the feed." => sub {
        my ($id, $token) = ($feed->{identifier}, $feed->{token});

        subtest "Without tokens, expect failures" => sub {
            my $tx = $ua->post(
                FEEDRO . "/feed/${id}/items",
                json => {
                    title => "Some random stuff",
                    content_text => "XXX",
                    url => "https://example.com",
                }
            );
            is $tx->result->code, "401",
        };

        subtest "With the correct token, expect successes" => sub {
            my $tx = $ua->post(
                FEEDRO . "/feed/${id}/items",
                { Authentication => "Bearer $token" },
                json => {
                    title => "Some random stuff",
                    content_text => "XXX",
                    url => "https://example.com",
                }
            );
            is $tx->result->code, "200";
        };

        subtest "With author, expect successes" => sub {
            my $tx = $ua->post(
                FEEDRO . "/feed/${id}/items",
                { Authentication => "Bearer $token" },
                json => {
                    title => "Some random stuff",
                    content_text => "XXX",
                    url => "https://example.com",
                    author => {
                        name => "Someone",
                    }
                }
            );
            is $tx->result->code, "200";
        };
    };

    subtest "Delete all items from the feed" => sub {
        my ($id, $token) = ($feed->{identifier}, $feed->{token});
        subtest "No token, expecting failures." => sub {
            my $tx = $ua->delete(FEEDRO . "/feed/${id}/items");
            is $tx->res->code, 401;
            is $tx->res->json, {
                error => D(),
            };
        };

        subtest "Correct token, expecting successful." => sub {
            my $tx = $ua->delete(
                FEEDRO . "/feed/${id}/items",
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

test_failure_creation;
test_item_crud;

done_testing;
