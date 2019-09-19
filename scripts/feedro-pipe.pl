#!/usr/bin/env perl
use v5.18;
use strict;
use warnings;
use Encode qw< decode_utf8 >;
use Mojo::UserAgent;
use Getopt::Long qw< GetOptions >;
use JSON;
use Data::UUID;
use XML::Loy;

sub fetch_feed_items {
    my ($url) = @_;

    my $ua = Mojo::UserAgent->new;
    my $tx = $ua->get($url);

    my $body = decode_utf8 $tx->result->body;

    my $xml = XML::Loy->new($body);

    my @rows;
    # rss
    $xml->find("item")->each(
        sub {
            my $el = $_;
            push @rows, {
                title => $el->at("title")->text,
                url   => $el->at("link")->text,
            };
        }
    );

    # atom
    $xml->find("entry")->each(
        sub {
            my $el = $_;
            my %o = (
                title => $el->at("title") // '',
                url   => $el->at("link")->attr("href") // '',
            );
            for my $k (keys %o) {
                $o{$k} = $o{$k}->text if ref($o{$k});
                $o{$k} =~ s/\s+/ /g;
            }
            push @rows, \%o;
        }
    );

    return \@rows;
}

my %opts;
GetOptions(
    \%opts,
    "from=s",
    "token=s"
);

my $feed_url = $ARGV[0] or die "A feed URL is required.";
$feed_url =~ s{\.json}{/items};

for (qw< from token >) {
    die "`$_` is required.\n" unless $opts{$_};
}

my @items = @{ fetch_feed_items($opts{from}) };

my $ua = Mojo::UserAgent->new;
for my $item (@items) {
    my $tx = $ua->post(
        $feed_url,
        { Authentication => "Bearer $opts{token}" },
        json => $item,
    );
    my $res = $tx->result;

    unless ($res->is_success) {
        say "Error: " . $res->message;
        say "\t" . $res->code;
        say "\t" . $res->body;
    }
}
