using ProgressMeter

"""
    mcmc(gp::GPBase; kwargs...)

Run MCMC algorithms provided by the Klara package for estimating the hyperparameters of
Gaussian process `gp`.
"""
function mcmc(gp::GPBase; nIter::Int=1000, burn::Int=1, thin::Int=1, ε::Float64=0.1,
              Lmin::Int=5, Lmax::Int=15, lik::Bool=true, noise::Bool=true,
              domean::Bool=true, kern::Bool=true)
    precomp = init_precompute(gp)
    params_kwargs = get_params_kwargs(gp; domean=domean, kern=kern, noise=noise, lik=lik)
    count = 0
    function calc_target!(gp::GPBase, θ::AbstractVector) #log-target and its gradient
        count += 1
        try
            set_params!(gp, θ; params_kwargs...)
            update_target_and_dtarget!(gp, precomp; params_kwargs...)
            return true
        catch err
            if !all(isfinite.(θ))
                return false
            elseif isa(err, ArgumentError)
                return false
            elseif isa(err, LinearAlgebra.PosDefException)
                return false
            else
                throw(err)
            end
        end
    end

    θ_cur = get_params(gp; params_kwargs...)
    D = length(θ_cur)
    leapSteps = 0                   #accumulator to track number of leap-frog steps
    post = Array{Float64}(undef, nIter, D)     #posterior samples
    post[1,:] = θ_cur

    @assert calc_target!(gp, θ_cur)
    target_cur, grad_cur = gp.target, gp.dtarget

    num_acceptances = 0
    for t in 1:nIter
        θ, target, grad = θ_cur, target_cur, grad_cur

        ν_cur = randn(D)
        ν = ν_cur + 0.5 * ε * grad

        reject = false
        L = rand(Lmin:Lmax)
        leapSteps +=L
        for l in 1:L
            θ += ε * ν
            if  !calc_target!(gp,θ)
                reject=true
                break
            end
            target, grad = gp.target, gp.dtarget
            ν += ε * grad
        end
        ν -= 0.5*ε * grad

        if reject
            post[t,:] = θ_cur
        else
            α = target - 0.5 * ν'ν - target_cur + 0.5 * ν_cur'ν_cur
            u = log(rand())

            if u < α
                num_acceptances += 1
                θ_cur = θ
                target_cur = target
                grad_cur = grad
            end
            post[t,:] = θ_cur
        end
    end
    post = post[burn:thin:end,:]
    set_params!(gp, θ_cur; params_kwargs...)
    @printf("Number of iterations = %d, Thinning = %d, Burn-in = %d \n", nIter,thin,burn)
    @printf("Step size = %f, Average number of leapfrog steps = %f \n", ε,leapSteps/nIter)
    println("Number of function calls: ", count)
    @printf("Acceptance rate: %f \n", num_acceptances/nIter)
    return post'
end


"""
    ess(gp::GPBase; kwargs...)

Sample GP hyperparameters using the elliptical slice sampling algorithm described in,

Murray, Iain, Ryan P. Adams, and David JC MacKay. "Elliptical slice sampling." 
Journal of Machine Learning Research 9 (2010): 541-548.

Requires hyperparameter priors to be Gaussian.
"""
function ess(gp::GPE; nIter::Int=1000, burn::Int=1, thin::Int=1, lik::Bool=true,
             noise::Bool=true, domean::Bool=true, kern::Bool=true)
    params_kwargs = get_params_kwargs(gp; domean=domean, kern=kern, noise=noise, lik=lik)
    count = 0
    function calc_target!(θ::AbstractVector)
        count += 1
        try
            set_params!(gp, θ; params_kwargs...)
            update_target!(gp; params_kwargs...)
            return gp.target
        catch err
            if(!all(isfinite.(θ))
               || isa(err, ArgumentError)
               || isa(err, LinearAlgebra.PosDefException))
                return -Inf
            else
                throw(err)
            end
        end
    end

    function sample!(f::AbstractVector, likelihood)
        v     = sample_params(gp; params_kwargs...)
        u     = rand()
        logy  = likelihood(f) + log(u);
        θ     = rand()*2*π;
        θ_min = θ - 2*π;
        θ_max = θ;
        f_prime = f * cos(θ) + v * sin(θ);
        props = 1
        while likelihood(f_prime) <= logy
            props += 1
            if θ < 0
                θ_min = θ;
            else
                θ_max = θ;
            end
            θ = rand() * (θ_max - θ_min) + θ_min;
            f_prime = f * cos(θ) + v * sin(θ);
        end
        return f_prime, props
    end

    total_proposals = 0
    θ_cur = get_params(gp; params_kwargs...)
    D = length(θ_cur)
    post = Array{Float64}(undef, nIter, D)

    for i = 1:nIter
        θ_cur, num_proposals = sample!(θ_cur, calc_target!)
        post[i,:] = θ_cur
        total_proposals += num_proposals
    end

    post = post[burn:thin:end,:]
    set_params!(gp, θ_cur; params_kwargs...)
    @printf("Number of iterations = %d, Thinning = %d, Burn-in = %d \n", nIter,thin,burn)
    println("Number of function calls: ", count)
    @printf("Acceptance rate: %f \n", nIter / total_proposals)
    return post'
end


"""
    lss(gp::GPBase; kwargs...)

Sample GP hyperparameters and latent functions using the slice sampling algorithm described in,

Murray, Iain, and Ryan P. Adams. "Slice sampling covariance hyperparameters of 
latent Gaussian models." Advances in Neural Information Processing Systems 10.
"""
function lss(gp::GPA; auxNoise::Float64=0.1, σ::Float64=0.1, nIter::Int=1000,
             burn::Int=1, thin::Int=1, lik::Bool=true, noise::Bool=true,
             domean::Bool=true, kern::Bool=true)
    params_kwargs = get_params_kwargs(gp; domean=domean, kern=kern, noise=noise, lik=lik)
    count = 0

    function update_gp!(θ::AbstractVector)
        count += 1
        try
            set_params!(gp, θ; process=true, params_kwargs...)
            update_target!(gp; params_kwargs...)
        catch err
            if(all(isfinite.(θ))
               && !isa(err, ArgumentError)
               && !isa(err, LinearAlgebra.PosDefException))
                throw(err)
            end
        end
    end

    function build_surrogate(K::PDMats.PDMat, f)
        Kii = K.mat[diagind(K.mat)]
        S   = Diagonal(max.(1 ./((1 ./auxNoise) .- (1 ./Kii)), 0.0))
        R   = PDMats.PDMat(S * (I - inv(PDMats.PDMat(K.mat + S)).mat * S))
        return PDMats.PDiagMat(S.diag), R 
    end

    function calc_target(f::AbstractVector, g::AbstractVector, θ::AbstractVector,
                         S::AbstractMatrix, R::AbstractMatrix)
        logθ = prior_logpdf(gp.lik) + prior_logpdf(gp.mean) + prior_logpdf(gp.kernel)
        logL = sum(log_dens(gp.lik,f,gp.y))
        logN = logpdf(MultivariateNormal(zeros(length(g)), gp.cK.mat + S), g)
        return logθ + logL + logN
    end

    function sample(f::AbstractVector, θ::AbstractVector, likelihood)
        S, R = build_surrogate(gp.cK, f)
        g = rand(MultivariateNormal(f, S))
        mθg = R * (S \ g)
        η = whiten(R, f - mθg)
        v = rand(Uniform(0,σ), length(θ))
        θ_min = θ - v
        θ_max = θ_min .+ σ

        u    = rand(Uniform(0,1))
        logy = log(u) + calc_target(f, g, θ, Diagonal(S.diag), R.mat)

        props = 0
        while true
            props += 1
            θ_prime = rand(Product(Uniform.(θ_min, θ_max)))
            update_gp!(vcat(η, θ_prime))
            S, R = build_surrogate(gp.cK, f)
            mθg = R * (S \ g)
            f_prime = unwhiten(R, η) + mθg

            println(calc_target(f_prime, g, θ_prime, Diagonal(S.diag), R.mat), " ", logy)
            if calc_target(f_prime, g, θ_prime, Diagonal(S.diag), R.mat) > logy
                return f_prime, η, θ_prime, props
            elseif θ_prime < θ 
                θ_min = θ_prime;
            else
                θ_max = θ_prime;
            end
        end
    end

    total_proposals = 0
    num_latent = gp.nobs

    params = get_params(gp; params_kwargs...)
    θ_cur = params[num_latent+1:end]
    f_cur = unwhiten(gp.cK,gp.v) + gp.μ 
    D     = length(θ_cur) + num_latent
    post  = Array{Float64}(undef, nIter, D)

    for i = 1:nIter
        println("start!!!")
        f_cur, η_cur, θ_cur, num_proposals = sample(f_cur, θ_cur, calc_target)
        post[i,1:num_latent]     = η_cur
        post[i,num_latent+1:end] = θ_cur
        total_proposals += num_proposals
    end

    post = post[burn:thin:end,:]
    set_params!(gp, θ_cur; params_kwargs...)
    @printf("Number of iterations = %d, Thinning = %d, Burn-in = %d \n", nIter,thin,burn)
    println("Number of function calls: ", count)
    @printf("Acceptance rate: %f \n", nIter / total_proposals)
    return post'
end
