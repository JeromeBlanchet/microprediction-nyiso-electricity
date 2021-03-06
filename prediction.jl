# This file contains everything associated with previously
# created running saved models.
#
# Copyright 2020. Rusty Conover (rusty@conover.me)

using Microprediction

cached_forecasts = Dict()

cached_latest_values = Dict()

"""
    runSavedModel(
        safe_filename_prefix::String,
        stream_update_interval::Minute=Dates.Minute(5),
        stream_name::String,
        number_of_points::Number=225,
        lag_interval::Number
    )

Execute a saved model to produce a set of points that describe
the predicted distribution.

"""
function runSavedModel(;
    identity_name::String,
    save_filename_prefix::String,
    stream_update_interval::Minute=Dates.Minute(5),
    stream_name::String,
    run_start_time::DateTime,
    number_of_points::Number=225,
    lag_interval::Number)

    full_filename = "$(save_filename_prefix)-lag-$(lag_interval).binary"

    saved_model = deserialize(full_filename)

    # Get the latest stream values.
    read_config = Microprediction.Config()

    if haskey(cached_latest_values, stream_name)
        live_lagged_values = cached_latest_values[stream_name]
    else
        cached_latest_values[stream_name] =
        live_lagged_values = Microprediction.get_lagged(read_config, stream_name)
    end

    # Since the history doesn't name the value in the TimeArray just
    # deal with this in a hardcoded way.
    latest_value = values(live_lagged_values)[end]

    latest_stream_update_time = timestamp(live_lagged_values)[end]

    # Calculate at which the forecast should be produced
    forecast_target_time = run_start_time + stream_update_interval * lag_interval

    forecast_cache_key = "$(forecast_target_time)-$(saved_model[:forecast_locations])"
    if haskey(cached_forecasts, forecast_cache_key)
        live_weather = cached_forecasts[forecast_cache_key]
    else
        cached_forecasts[forecast_cache_key] =
        live_weather = latestHRRRForecastForTime(forecast_target_time, saved_model[:forecast_locations])
    end

    nyiso_forecast = loadNYISOLoadForecasts()

    # Since the weather data is interpolated to the nearest minute
    # round appropriately
    rounded_forecast_time = round(forecast_target_time, Dates.Minute)

    # Get the weather data.
    weather_data = live_weather[rounded_forecast_time]

    nyiso_data = nyiso_forecast[rounded_forecast_time]

    zscore_result::Dict{Symbol,Any} = Dict()
    zscore_result[:datetime] = timestamp(weather_data)

    # Z-score the demand lag.
    zscore_result[:Demand_lag] = (latest_value - saved_model[:stats][:Demand_lag][1]) / saved_model[:stats][:Demand_lag][2]

    # Get the start time.
    stream_start = saved_model[:stream_start]
    periodic_ticks = round((forecast_target_time - stream_start) / Dates.Millisecond(1000 * 60 * 5))

    zscore_result[:sin_288] = sin(2 * pi * periodic_ticks / 288)
    zscore_result[:cos_288] = cos(2 * pi * periodic_ticks / 288)
    zscore_result[:sin_2016] = sin(2 * pi * periodic_ticks / 2016)
    zscore_result[:cos_2016] = cos(2 * pi * periodic_ticks / 2016)

    for c in colnames(weather_data)
        # Zscore the variable by the same mu and std calculated
        # when the model was trained.
        (mu, std) = saved_model[:stats][c]
        zscore_result[c] = (values(weather_data[c])[1] - mu) / std
    end

    # Merge in all of the nyiso forecasts.
    for c in colnames(nyiso_data)
        (mu, std) = saved_model[:stats][c]
        zscore_result[c] = (values(nyiso_data[c])[1] - mu) / std
    end

    zscored_data = TimeArray(namedtuple(zscore_result); timestamp=:datetime)

    # Now build the regressor inputs for the model.
    regressor_values = convert(Array{Float32,2}, values(zscored_data[saved_model[:regressors]...]))

    model_result = saved_model[:model](vcat(regressor_values...))

    reverse_z(v, stat) = (v * stat[2]) + stat[1]


    if haskey(saved_model, :points_output) && saved_model[:points_output]
        points = map(x -> reverse_z(x, saved_model[:stats][:Demand_diff]), model_result) .+ latest_value
    else
        mu = model_result[1]
        std = softplus(model_result[2])

        distribution = saved_model[:distribution](mu, std)


        # Now do the trick by iterating across the quantile function
        # thanks Peter.
        smidge = 1 / (number_of_points + 2)
        points = map(x -> reverse_z(quantile(distribution, x), saved_model[:stats][:Demand_diff]) + latest_value, smidge:smidge:1 - (smidge * 2))
    end

    points_stats = mean_and_std(points)
    @printf "%s %s lag=%d latest=%f mu=%.2f std=%.2f points mu=%.2f std=%.2f\n" identity_name saved_model[:stream] lag_interval latest_value mu std points_stats[1] points_stats[2]

    return Dict(
        :stream_name => saved_model[:stream],
        :points => points)
end





function makeDemandStreams()
    all_demand_streams = [
        "electricity-load-nyiso-north.json",
        "electricity-load-nyiso-overall.json",
        "electricity-load-nyiso-centrl.json",
        "electricity-load-nyiso-hud_valley.json",
        "electricity-load-nyiso-millwd.json",
        "electricity-load-nyiso-mhk_valley.json",
        "electricity-load-nyiso-nyc.json",
        "electricity-load-nyiso-capitl.json",
        "electricity-load-nyiso-genese.json",
        "electricity-load-nyiso-west.json",
        "electricity-load-nyiso-dunwod.json",
        "electricity-load-nyiso-longil.json",
    ]

    for stream_name in all_demand_streams
        build_demand_stream(
            stream_name=stream_name,
            use_points=true,
            save_filename_prefix="demand-points-$(stream_name)",
            max_epochs=400)
    end

end



"""
    runSavedModels(write_key)

Execute all of the saved models and send their predictions to
Microprediction.

"""
function runSavedModels(write_key::String="8f0fb3ce57cb67498e3790f9d64dd478")
    while true
#        println("$(now()) Starting prediction run")
#        println("Doing solar")

        # Set the time for ths model run so the forecasts can
        # hopefully be cached.
        run_time = now(UTC)
        global cached_forecasts = Dict()
        global cached_latest_values = Dict()

        # Non points stream.
        write_key =
        all_demand_streams = [
            "electricity-load-nyiso-overall.json",
            "electricity-load-nyiso-north.json",
            "electricity-load-nyiso-centrl.json",
            "electricity-load-nyiso-hud_valley.json",
            "electricity-load-nyiso-millwd.json",
            "electricity-load-nyiso-mhk_valley.json",
            "electricity-load-nyiso-nyc.json",
            "electricity-load-nyiso-capitl.json",
            "electricity-load-nyiso-genese.json",
            "electricity-load-nyiso-west.json",
            "electricity-load-nyiso-dunwod.json",
            "electricity-load-nyiso-longil.json",
        ]

        for stream_name in all_demand_streams
            submitSavedModelPrediction(
                run_start_time=run_time,
                identity_name="Flex Hedgehog",
                write_key="8f0fb3ce57cb67498e3790f9d64dd478", # Flex Hedgehog
                save_filename_prefix="demand-$(stream_name)",
                stream_update_interval=Dates.Minute(5),
                stream_name=stream_name)
        end

        # Message Moose - points based models.
        for stream_name in all_demand_streams
            submitSavedModelPrediction(
                run_start_time=run_time,
                identity_name="Message Moose",
                write_key="7e5d0f66b23def57c5f9bcee73ab45dd", # Message Moose
                save_filename_prefix="demand-points-$(stream_name)",
                stream_update_interval=Dates.Minute(5),
                stream_name=stream_name)
        end


#        println("Doing wind")
#        submit_running_model(save_filename_prefix="production-wind3", stream_update_interval=Dates.Minute(5), stream_name="electricity-fueltype-nyiso-wind.json")

#        println("Doing overall")
#        submit_running_model(save_filename_prefix="production-load-overall-no-exp", stream_update_interval=Dates.Minute(5), stream_name="electricity-load-nyiso-overall.json")

        # streams = [
        #      "electricity-fueltype-nyiso-other_renewables.json",
        #      "electricity-fueltype-nyiso-wind.json",
        #      "electricity-load-nyiso-overall.json",
        #  ]
        # for stream in streams
        #     cancelPredictions(write_key=write_key, stream_name=stream)
        # end
        # println("$(now()) all done")
        sleep(60 * 5)
    end
end


function submitSavedModelPrediction(;
    write_key::String,
    identity_name::String,
    run_start_time::DateTime,
    save_filename_prefix::String,
    stream_update_interval::Minute,
    stream_name::String)

    lag_interval_to_competition = Dict(
        1 => [70, 310],
        3 => [910],
        12 => [3555]
    )

    # Send the prediction in.
    write_config = Microprediction.Config(write_key)

    for (lag_interval, competition_delays) in sort(collect(lag_interval_to_competition))
        output = runSavedModel(
            save_filename_prefix=save_filename_prefix,
            identity_name=identity_name,
                    lag_interval=lag_interval,
                    run_start_time=run_start_time,
                    stream_update_interval=stream_update_interval,
                    stream_name=stream_name)

        points = output[:points]
        if contains(output[:stream_name], "fueltype")
            points = round.(points)
        end

        # Should write this to a file.
        io = open("prediction-log.json", "a")
        for competition_delay in competition_delays
            println(io,
            JSON.json(Dict(
                :stream_name => stream_name,
                :write_key => write_key,
                :time => convert(Int64, round(datetime2unix(now(UTC)))),
                :points => points,
                :save_filename_prefix => save_filename_prefix,
                :delay => competition_delay)))
            Microprediction.submit(write_config, output[:stream_name], convert(Array{Float64}, points), competition_delay);
        end
        close(io)
    end

end

function cancelPredictions(;
    write_key::String,
    stream_name::String)
    # Send the prediction in.
    write_config = Microprediction.Config(write_key)

    lag_interval_to_competition = Dict(
        1 => [70, 310],
        3 => [910],
        12 => [3555]
    )

    for (lag_interval, competition_delays) in lag_interval_to_competition
        for competition_delay in competition_delays
            @async Microprediction.cancel(write_config, stream_name, competition_delay)
        end
    end
end#