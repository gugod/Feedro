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
    my $feed = $res->json;

    is $res->code, "200", "A successful code";
    is $feed, {
        identifier => D(),
        token => D(),
    }, "The structure of successful response";
}

sub test_failure_creation {
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
    is $feed, {
        error => D(),
    };
}

test_failure_creation;
test_successful_creation;
done_testing;
