# Copyright (C) 2021 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package MirrorCache::WebAPI::Plugin::Subsidiary;
use Mojo::Base 'Mojolicious::Plugin';

my $subsidiary_region;

my $subsidiaries_initialized = 0;
my %subsidiary_urls;
my %subsidiary_local;
my @regions;

sub register {
    my ($self, $app) = @_;
    my @subsidiaries;
    # having MIRRORCACHE_REGION means that we are Subsidiary
    if ($ENV{MIRRORCACHE_REGION}) {
        $subsidiary_region = lc($ENV{MIRRORCACHE_REGION});
        $app->helper('subsidiary.has'     => sub { return undef; });
        $app->helper('subsidiary.regions' => sub { return undef; });
    } else {
        eval { #the table may be missing - no big deal
            @subsidiaries = $app->schema->resultset('Subsidiary')->all;
        };
        for my $s (@subsidiaries) {
            my $url = $s->hostname;
            $url = "http://" . $url unless 'http' eq substr($url, 0, 4);
            $url = $url . $s->uri if $s->uri;
            my $region = lc($s->region);
            next unless $region;
            push @regions, $region;
            my $obj = Mojo::URL->new($url)->to_abs;
            $subsidiary_urls{$region} = $obj;
            $subsidiary_local{$region} = 1 if $s->local;

            $app->routes->get("/rest/$region" => sub {
                my $c = shift;
                my $file = $c->param('file');
                return $c->render(status => 400) unless $file;
                my $dm = MirrorCache::Datamodule->new->app($c->app);
                $dm->reset($c);

                my $req = $obj->clone;
                $req->scheme($c->req->url->to_abs->scheme);
                $req->path($req->path . $file);
                my $country = $dm->country;
                my $region  = $dm->region;
                $req->query('mirrorlist&json');
                $req->query->merge(COUNTRY => $country) if $country;
                $req->query->merge(REGION  => $region)  if $region;
                $c->proxy->get_p($req);
            });
         }

         $app->helper('subsidiary.has'     => \&_has_subsidiary);
         $app->helper('subsidiary.regions' => \&_regions);
    }
    return $self;
}

sub _has_subsidiary {
    return undef unless keys %subsidiary_urls;
    my ($self, $region, $origin_url) = @_;
    my $region_url = $subsidiary_urls{$region};
    return $region_url unless $region_url && $origin_url;
    my $url = $origin_url->to_abs->clone;
    $url->host($region_url->host);
    $url->port($region_url->port);
    $url->path_query($region_url->path . $url->path_query) if ($region_url->path);
    my $reg = $region_url->to_abs->clone;
    $reg->scheme($url->scheme);
    return ($url, $reg);
}

# return url for all subsidiaries
sub _regions {
    return undef unless keys %subsidiary_urls;
    my ($self, $region) = @_;
    my $url = $subsidiary_urls{$region};
    my @res = ($url? $region : '');

    for my $s (@regions) {
        next if $region eq $s;
        next if $subsidiary_local{$s};
        push @res, $s;
    }

    return @res;
}

1;
