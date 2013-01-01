package Odyssey;

use Dancer ':syntax';

use Data::FormValidator;
use Date::Manip::Date;
use Data::Dumper;

use DateTime::Format::Strptime;
	  
use Odyssey::MemcacheDB;;
use Odyssey::RouteFinder;

our $VERSION = '0.1';

get '/' => sub {
	
	return redirect(uri_for('/diy'));
};

get '/tview/:template' => sub {
	
	my $template = params->{template};
	template $template;
};

get '/diy' => sub {
	
	my $cities = startcities();
	my @airports = grep {$_->{airport}} @$cities;

	my $valid = {
		pax => 2,
		hotelcategory => 10,
		double => 1,
		arrplace => 103,
		depplace => 103,
		startplace => 2,
	};
	
	template diy => {
		cities => $cities, 
		airports => \@airports,
		valid => $valid,
	};
};

post '/diy' => sub {
	
	my $results = validate_diy({
		leadname		=> params->{leadname},
		pax				=> params->{pax},
		hotelcategory	=> params->{hotelcategory},
		arrdate			=> params->{arrdate},
		arrplace		=> params->{arrplace},
		startplace		=> params->{startplace},
		depdate			=> params->{depdate},
		depplace		=> params->{depplace},
		single			=> params->{single},
		double			=> params->{double},
		twin			=> params->{twin},
	});

	my $valid = $results->valid;
	if (! $results->success) {
		
		my $cities = startcities();
		my @airports = grep {$_->{airport}} @$cities;
		
		return template diy => {
			cities => $cities, 
			airports => \@airports, 
			err => $results->msgs,
			valid => $valid,
		};
	}
	
	# We store all timestamps in YYYY-MM-DD HH24:MM:SS format
	# required so template toolkit can parse the date
	my $dmd = Date::Manip::Date->new;
	$dmd->parse($valid->{arrdate});
	my $atstmp = $dmd->printf('%Y-%m-%d');

	$dmd->new_date;
	$dmd->parse($valid->{depdate});
	my $dtstmp = $dmd->printf('%Y-%m-%d');

	
	# Init session user
	my ($currcity, $lat, $lng) = @{city($valid->{arrplace})};
	my ($city) = @{city($valid->{startplace})};

	session status => {
		config => {
			leadname		=> $valid->{leadname},
			pax				=> $valid->{pax},
			hotelcategory	=> $valid->{hotelcategory},
			single			=> $valid->{single},
			double			=> $valid->{double},
			twin			=> $valid->{twin},
			arrdate			=> $atstmp,
			arrplace		=> $valid->{arrplace},
			startplace		=> $valid->{startplace},
			depdate			=> $dtstmp,
			depplace		=> $valid->{depplace},
		},
		src => {
			cityid		=> $valid->{arrplace},
			city		=> $currcity,
			lat			=> $lat,
			lng			=> $lng,
			daynum		=> 1,
			date 		=> $atstmp . ' 00:00:00',
			etd			=> $atstmp . ' 09:00:00',
		},
		dest => {
			cityid			=> $valid->{startplace},
			city			=> $city,
			routes			=> []
		},
		stops => [],
	};
	
	return redirect uri_for('explore/' . $city);
};

post '/explore' => sub {
	
	# Just a redirector for random cities
	
	# Go to DIY Form if no session and non-existent city
	return redirect uri_for('diy') 
		unless ((my $status = session('status')) && (my $city = params->{rcity}));

	return redirect uri_for('/explore/' . $city );
};

get '/explore/:city' => sub {
	
	my $city = params->{city};

	# Go to DIY Form if no session and non-existent city
	return redirect uri_for('diy') 
		unless ((my $status = session('status')) && (my $destid = cityid($city)));

	# What follows - assumes that all is well
	my $from 	= $status->{src}{cityid};
	my $to		= $destid;
	my $hpref 	= $status->{config}{hotelcategory};
		
	my $citydetails = {

		%{citydetails($to)},
		hotels 		=> cityhotels($to),
		defhotel 	=> defaulthotel($to, $hpref),
		nearcities 	=> nearcities($from),
		randomcities => randomcities(),
		routes 		=> (my $routes = routefinder($from, $to, $status->{src}{etd})),
	};

	# Update destination and routes.
	session status => {
		%{session('status')},
		dest => {
			cityid => $destid,
			city => $city,
			routes => $routes,
		}
	};
	
	template move_to => $citydetails;
};

post '/transit' => sub {
	
	# Go to DIY Form if no session and non-existent city
	my $status = session('status');
	
	return redirect uri_for('diy') 
		unless $status  && $status->{dest}{routes};

	my $params = params;

	my $city = $status->{dest}{city};
	my (undef, $lat, $lng) = @{city($status->{dest}{cityid})};
	
	my $route = $status->{dest}{routes}[$params->{travelopts}];
	debug to_dumper($route);
	
	my $days = $params->{days};
	my ($daynum, $date) = departuredate(
		$status->{config}{arrdate},
		$route->{hops}[-1]{arrival}, 
		$days
	);
	
	my $hotelid = $params->{hotelid};
	my $hotel = hotel($hotelid);
	
	debug "Hotel: $hotel";
	
	push @{$status->{stops}}, {
		src => $status->{src},
		dest => {%{$status->{dest}}, routes => {}},
		route => $route,
		hotelid => $hotelid,
		hotel => $hotel,
		arrdate => $route->{hops}[-1]{arrival},
		depdate => $date . ' 00:00:00.000',
		days => $days,
	};
		
	session status => {
		%$status,
		src => {
			cityid		=> $status->{dest}{cityid},
			city		=> $status->{dest}{city},
			lat			=> $lat,
			lng			=> $lng,
			daynum		=> $daynum,
			date 		=> $date . ' 00:00:00',
			etd			=> $date . ' 09:00:00',
		},
		dest => {},
	};
	
	return redirect(uri_for('/explore_around/' . $city));
};

get '/explore_around/:city' => sub {
	
	# Go to DIY Form if no session and non-existent city
	my $status = session('status');
	debug to_dumper($status);
	
	my $city = param 'city';

	return redirect uri_for('diy') 
		unless (
			$status &&
			(my $cityid = $status->{src}{cityid}) &&
			($city eq $status->{src}{city})
		);
		
	my $options = nearcities($cityid);
	
	my $stops = build_accoquote();
	debug to_dumper($stops);
	
	template move_on => {
		cities => $options, 
		randomcities => randomcities()
	};	
};

sub validate_diy {
	
	my $inp = shift;
	
	my $dfv = {
		filters => ['trim'],
		required => [qw{
			leadname
			pax
			hotelcategory
			arrdate
			arrplace
			startplace
			depdate
			depplace
		}],
		require_some => {
			bedroom_type => [
				1, 
				qw{
					single
					double
					twin
				}
			]
		},
		constraints => {
			arrdate => {
				name => 'valid_date',
				constraint => \&validate_date,
			},
			depdate => {
				name => 'valid_date',
				constraint => \&validate_date,
			},
			depdate => {
				name => 'depart_after_arrive',
				params => [qw{arrdate depdate}],
				constraint => sub {

					my ($arr, $dep) = @_;
					
					my $arrd = Date::Manip::Date->new;
					my $depd = Date::Manip::Date->new;

					$arrd->parse($arr);
					$depd->parse($dep);
					
					return ($arrd->cmp($depd) == 1) ? 0 : 1;
				}
			}
		},
		msgs => {
			missing => 'This field is required',
			invalid => 'This value is invalid',
			constraints => {
				depart_after_arrive => 'Departure Date cannot be before Arrival',
				bedroom_type => 'At least one room type must be chosen',
				require_some => 'At least one room type must be chosen',
			},
		},
		debug => 1,
	};
	
	return my $results = Data::FormValidator->check($inp, $dfv);
}

sub validate_date {
	
	my $d = pop;
	
	my $dd = new Date::Manip::Date;
	my $err = $dd->parse($d);	

	return ! $err;
}

sub build_accoquote {
	
	my $status = session('status');
	return undef unless
		$status && (my $stops = $status->{stops});
	
	my @quotes = ();
	foreach (@{$stops}) {
		
		push @quotes, {
			cityid => $_->{dest}{cityid},
			city => $_->{dest}{city},
			hotelid => $_->{hotelid},
			hotel => $_->{hotel},
			from => $_->{arrdate},
			to => $_->{depdate},
			days => $_->{days},
		};
	}

	return \@quotes;	
}

true;