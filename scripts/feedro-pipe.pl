#!/usr/bin/env perl
use v5.18;
use strict;
use warnings;
use Encode qw< encode_utf8 decode_utf8 >;
use Mojo::UserAgent;
use Getopt::Long qw< GetOptions >;
use Digest::SHA1 qw< sha1_hex >;
use JSON;
use Data::UUID;
use XML::Loy;
use NewsExtractor;

sub extract_fulltext {
    my ($url) = @_;
    my ($error, $article);
    eval {
        ($error, $article) = NewsExtractor->new( url => $url )->download->parse;
        1;
    } or return;

    return if $error;
    return ($article->headline, $article->article_body);
}

sub fetch_feed_items {
    my ($url, $opts, $cb) = @_;

    my $ua = Mojo::UserAgent->new;
    my $tx = $ua->get($url);

    my $body = decode_utf8 $tx->result->body;

    my $xml = XML::Loy->new($body);

    my @items;
    # rss
    $xml->find("item")->each(
        sub {
            my $el = $_;
            push @items, {
                title => $el->at("title"),
                url   => $el->at("link"),
                date_published => $el->at("date"),
                content_text => $el->at("description"),
            };
        }
    );

    # atom
    $xml->find("entry")->each(
        sub {
            my $el = $_;
            my %o = (
                title        => $el->at("title"),
                summary      => $el->at("summary"),
                content_text => $el->at("content"),
                date_published => $el->at("published"),
            );

            if ($el->at("link")) {
                $o{url} = $el->at("link")->attr("href");
            }

            if (!defined($o{content_text}) && defined($o{summary})) {
                $o{content_text} = delete $o{summary};
            }

            push @items, \%o;
        }
    );

    if ( $opts->{"ignore-items-without-url"} ) {
        @items = grep { $_->{url} } @items;
    }

    for my $o (@items) {
        for my $k (keys %$o) {
            unless (defined $o->{$k}) {
                delete $o->{$k};
                next;
            }

            $o->{$k} = $o->{$k}->all_text() if ref($o->{$k});
            $o->{$k} =~ s/\A\s+//;
            $o->{$k} =~ s/\s+\z//;
            $o->{$k} =~ s/\s+/ /g;
        }
    }

    if ( $opts->{'extract-fulltext'} ) {
        for my $item (grep { $_->{url} } @items) {
            my ($title, $content) =  extract_fulltext( $item->{url} );
            if (defined($title) && defined($content)) {
                $item->{title} = $title;
                $item->{content_text} = $content;

                $cb->([ $item ]);
            }
        }
    } else {
        if ($cb) {
            $cb->(\@items);
        }
    }

    return \@items;
}

sub post_to_feedro {
    my ($feed_url, $token, $items) = @_;

    my $ua = Mojo::UserAgent->new;
    for my $item (@$items) {
        my $tx = $ua->post(
            $feed_url,
            { Authentication => "Bearer $token" },
            json => $item,
        );
        my $res = $tx->result;
        unless ($res->is_success) {
            say "Error: " . $res->message;
            say "\t" . $res->code;
            say "\t" . $res->body;
        }
    }
}

my %opts;
GetOptions(
    \%opts,
    "from=s",
    "token=s",
    "ignore-items-without-url",
    "extract-fulltext",
);

my $feed_url = $ARGV[0] or die "A feed URL is required.";
$feed_url =~ s{\.json}{/items};

for (qw< from token >) {
    die "`$_` is required.\n" unless $opts{$_};
}

fetch_feed_items(
    $opts{from},
    {
        "extract-fulltext"         => $opts{"extract-fulltext"},
        "ignore-items-without-url" => $opts{"ignore-items-without-url"}
    },
    sub {
        my ($items) = @_;

        post_to_feedro(
            $feed_url,
            $opts{token},
            $items,
        );
    }
);
