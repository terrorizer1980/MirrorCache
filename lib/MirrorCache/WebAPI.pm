# Copyright (C) 2020 SUSE LLC
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
# with this program; if not, see <http://www.gnu.org/licenses/>.

package MirrorCache::WebAPI;
use Mojo::Base 'Mojolicious';

use Mojolicious::Commands;

use MirrorCache::Schema;
use MirrorCache::Utils 'random_string';

sub new {
    my $self = shift->SUPER::new;
    # setting pid_file in startup will not help, need to set it earlier
    $self->config->{hypnotoad}{pid_file} = $ENV{MIRRORCACHE_HYPNOTOAD_PID} // '/run/mirrorcache/hypnotoad.pid';
    $self;
}

# This method will run once at server start
sub startup {
    my $self = shift;
    my $root = $ENV{MIRRORCACHE_ROOT} || "";
    my $geodb_file = $ENV{MIRRORCACHE_CITY_MMDB} || $ENV{MIRRORCACHE_IP2LOCATION};

    die("Geo IP location database is not a file ($geodb_file)\nPlease check MIRRORCACHE_CITY_MMDB or MIRRORCACHE_IP2LOCATION") if $geodb_file && ! -f $geodb_file;
    my $geodb;

    eval {
        MirrorCache::Schema->singleton;
        1;
    } or die("Database connect failed: $@");

    eval {
        MirrorCache::Schema->singleton->migrate();
        1;
    } or die("Automatic migration failed: $@\nFix table structure and insert into mojo_migrations select 'mirrorcache',version");
    my $secret = random_string(16);
    $self->config->{hypnotoad}{listen}   = [$ENV{MOJO_LISTEN} // 'http://*:8080'];
    $self->config->{hypnotoad}{proxy}    = $ENV{MOJO_REVERSE_PROXY} // 0,
    $self->config->{hypnotoad}{workers}  = $ENV{MIRRORCACHE_WORKERS},
    # $self->config->{hypnotoad}{pid_file} = $ENV{MIRRORCACHE_HYPNOTOAD_PID}, - already set in constructor
    $self->config->{_openid_secret} = $secret;
    $self->secrets([$secret]);


    push @{$self->commands->namespaces}, 'MirrorCache::WebAPI::Command';

    $self->plugin('DefaultHelpers');
    my $current_version = $self->detect_current_version() || "unknown";
    $self->defaults(current_version => $current_version);
    $self->log->info("initializing $current_version");

    $self->defaults(branding => $ENV{MIRRORCACHE_BRANDING});

    $self->app->hook(before_server_start => sub {
        die("MIRRORCACHE_ROOT is not set") unless $root;
        if ((-1 == rindex($root, 'http', 0)) && (-1 == rindex($root, 'rsync://', 0)) ) {
            my $i = index($root, ':');
            my $dir = ($i > -1 ? substr($root, 0, $i) : $root);
            die("MIRRORCACHE_ROOT is not a directory ($root)") unless -d $dir;
        }

        # Optional initialization with access to the app
        my $r = $self->routes->namespaces(['MirrorCache::WebAPI::Controller']);
        $r->get('/favicon.ico' => sub { my $c = shift; $c->render_static('favicon.ico') });

        $r->get('/version')->to(cb => sub {
            shift->render(text => $current_version);
        }) if $current_version;
        $r->post('/session')->to('session#create');
        $r->delete('/session')->to('session#destroy');
        $r->get('/login')->name('login')->to('session#create');
        $r->post('/login')->to('session#create');
        $r->post('/logout')->name('logout')->to('session#destroy');
        $r->get('/response')->to('session#response');
        $r->post('/response')->to('session#response');

        my $rest = $r->any('/rest');
        my $rest_r    = $rest->any('/')->to(namespace => 'MirrorCache::WebAPI::Controller::Rest');
        $rest_r->get('/server')->name('rest_server')->to('table#list', table => 'Server');
        $rest_r->get('/server/:id')->to('table#list', table => 'Server');
        $rest_r->get('/project/:name')->to('project#show');
        $rest_r->get('/project/:name/mirror_summary')->to('project#mirror_summary');
        $rest_r->get('/project/:name/mirror_list')->to('project#mirror_list');

        my $rest_operator_auth;
        $rest_operator_auth = $rest->under('/')->to('session#ensure_operator');
        my $rest_operator_r = $rest_operator_auth->any('/')->to(namespace => 'MirrorCache::WebAPI::Controller::Rest');
        $rest_operator_r->post('/server')->to('table#create', table => 'Server');
        $rest_operator_r->post('/server/:id')->name('post_server')->to('table#update', table => 'Server');
        $rest_operator_r->delete('/server/:id')->to('table#destroy', table => 'Server');
        $rest_operator_r->put('/server/location/:id')->name('rest_put_server_location')->to('server_location#update_location');
        $rest_operator_r->post('/sync_tree')->name('rest_post_sync_tree')->to('folder_jobs#sync_tree');

        $rest_r->get('/folder')->name('rest_folder')->to('table#list', table => 'Folder');

        $rest_r->get('/folder_jobs/:id')->name('rest_folder_jobs')->to('folder_jobs#list');
        $rest_r->get('/myip')->name('rest_myip')->to('my_ip#show') if $geodb;

        $rest_r->get('/stat')->name('rest_stat')->to('stat#list');
        $rest_r->get('/mystat')->name('rest_mystat')->to('stat#mylist');

        my $app_r = $r->any('/app')->to(namespace => 'MirrorCache::WebAPI::Controller::App');

        $app_r->get('/server')->name('server')->to('server#index');
        $app_r->get('/folder')->name('folder')->to('folder#index');
        $app_r->get('/folder/<id:num>')->name('folder_show')->to('folder#show');

        my $admin = $r->any('/admin');
        my $admin_auth = $admin->under('/')->to('session#ensure_admin')->name('ensure_admin');
        my $admin_r = $admin_auth->any('/')->to(namespace => 'MirrorCache::WebAPI::Controller::Admin');

        $admin_r->delete('/folder/<id:num>')->to('folder#delete_cascade');
        $admin_r->delete('/folder_diff/<id:num>')->to('folder#delete_diff');

        $admin_r->get('/user')->name('get_user')->to('user#index');
        $admin_r->post('/user/:userid')->name('post_user')->to('user#update');

        my $rest_user_r = $admin_auth->any('/')->to(namespace => 'MirrorCache::WebAPI::Controller::Rest');
        $rest_user_r->delete('/user/<id:num>')->name('delete_user')->to('user#delete');

        $admin_r->get('/auditlog')->name('audit_log')->to('audit_log#index');
        $admin_r->get('/auditlog/ajax')->name('audit_ajax')->to('audit_log#ajax');

        $r->get('/index' => sub { shift->render('main/index') });
        $r->get('/' => sub { shift->render('main/index') })->name('index');

        $self->plugin(AssetPack => {pipes => [qw(Sass Css JavaScript Fetch Combine)]});
        $self->asset->process;
        $self->plugin('Stat');
        $self->plugin('Dir');
        $self->log->info("server started:  $current_version");
    });


    $self->plugin('RenderFile');

    push @{$self->plugins->namespaces}, 'MirrorCache::WebAPI::Plugin';

    $self->plugin('Backstage');
    $self->plugin('AuditLog');
    $self->plugin('RenderFileFromMirror');
    $self->plugin('HashedParams');

    if ($geodb_file && $geodb_file =~ /\.mmdb$/i) {
        require MaxMind::DB::Reader;
        $geodb = MaxMind::DB::Reader->new(file => $geodb_file);
        $self->plugin('Mmdb', { reader => $geodb });
    }
    elsif ($geodb_file && $geodb_file =~ /\.BIN$/i) {
        require Geo::IP2Location;
        $geodb = Geo::IP2Location->open($geodb_file);
        $self->plugin('Geolocation', { geodb => $geodb });
    }
    elsif ($geodb_file) {
        die("Unsupported geo IP location database ($geodb_file)\nPlease check MIRRORCACHE_CITY_MMDB or MIRRORCACHE_IP2LOCATION environment variables");
    }
    else {
        $self->plugin('Mmdb', { reader => $geodb });
    }

    $self->plugin('Helpers', root => $root, route => '/download');
    $self->plugin('Subsidiary');
    if ($root) {
        # check prefix
        if ('rsync://' eq substr($root, 0, 8)) {
            $self->plugin('RootRsync', { url => $root });
        } elsif (-1 == rindex $root, 'http', 0) {
            $self->plugin('RootLocal');
        } else {
            $self->plugin('RootRemote');
        }
    }
}

sub detect_current_version() {
    my $self = shift;
    eval {
        my $ver = `git rev-parse --short HEAD 2>/dev/null || :`;
        $ver = `rpm -q MirrorCache 2>/dev/null | grep -Po -- '[0-9]+\.[0-9a-f]+' | head -n 1 || :` unless $ver;
        $ver;
    } or $self->log->error('Cannot determine version');
}

sub schema { MirrorCache::Schema->singleton }

sub run { __PACKAGE__->new->start }

1;
