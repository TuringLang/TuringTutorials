---
title: Linear Regression
permalink: /:collection/:name/
---


Turing is powerful when applied to complex hierarchical models, but it can also be put to task at common statistical procedures, like [linear regression](https://en.wikipedia.org/wiki/Linear_regression). This tutorial covers how to implement a linear regression model in Turing.

## Set Up

We begin by importing all the necessary libraries.

````julia
# Import Turing and Distributions.
using Turing, Distributions

# Import RDatasets.
using RDatasets

# Import MCMCChains, Plots, and StatPlots for visualizations and diagnostics.
using MCMCChains, Plots, StatsPlots

# Set a seed for reproducibility.
using Random
Random.seed!(0);

# Hide the progress prompt while sampling.
Turing.turnprogress(false);
````




We will use the `mtcars` dataset from the [RDatasets](https://github.com/johnmyleswhite/RDatasets.jl) package. `mtcars` contains a variety of statistics on different car models, including their miles per gallon, number of cylinders, and horsepower, among others.

We want to know if we can construct a Bayesian linear regression model to predict the miles per gallon of a car, given the other statistics it has. Lets take a look at the data we have.

````julia
# Import the "Default" dataset.
data = RDatasets.dataset("datasets", "mtcars");

# Show the first six rows of the dataset.
first(data, 6)
````


````
6×12 DataFrame. Omitted printing of 6 columns
│ Row │ Model             │ MPG     │ Cyl   │ Disp    │ HP    │ DRat    │
│     │ String            │ Float64 │ Int64 │ Float64 │ Int64 │ Float64 │
├─────┼───────────────────┼─────────┼───────┼─────────┼───────┼─────────┤
│ 1   │ Mazda RX4         │ 21.0    │ 6     │ 160.0   │ 110   │ 3.9     │
│ 2   │ Mazda RX4 Wag     │ 21.0    │ 6     │ 160.0   │ 110   │ 3.9     │
│ 3   │ Datsun 710        │ 22.8    │ 4     │ 108.0   │ 93    │ 3.85    │
│ 4   │ Hornet 4 Drive    │ 21.4    │ 6     │ 258.0   │ 110   │ 3.08    │
│ 5   │ Hornet Sportabout │ 18.7    │ 8     │ 360.0   │ 175   │ 3.15    │
│ 6   │ Valiant           │ 18.1    │ 6     │ 225.0   │ 105   │ 2.76    │
````



````julia
size(data)
````


````
(32, 12)
````




The next step is to get our data ready for testing. We'll split the `mtcars` dataset into two subsets, one for training our model and one for evaluating our model. Then, we separate the labels we want to learn (`MPG`, in this case) and standardize the datasets by subtracting each column's means and dividing by the standard deviation of that column.

The resulting data is not very familiar looking, but this standardization process helps the sampler converge far easier. We also create a function called `unstandardize`, which returns the standardized values to their original form. We will use this function later on when we make predictions.

````julia
# Function to split samples.
function split_data(df, at = 0.70)
    r = size(df,1)
    index = Int(round(r * at))
    train = df[1:index, :]
    test  = df[(index+1):end, :]
    return train, test
end

# A handy helper function to rescale our dataset.
function standardize(x)
    return (x .- mean(x, dims=1)) ./ std(x, dims=1), x
end

# Another helper function to unstandardize our datasets.
function unstandardize(x, orig)
    return (x .+ mean(orig, dims=1)) .* std(orig, dims=1)
end

# Remove the model column.
select!(data, Not(:Model))

# Standardize our dataset.
(std_data, data_arr) = standardize(Matrix(data))

# Split our dataset 70%/30% into training/test sets.
train, test = split_data(std_data, 0.7)

# Save dataframe versions of our dataset.
train_cut = DataFrame(train, names(data))
test_cut = DataFrame(test, names(data))

# Create our labels. These are the values we are trying to predict.
train_label = train_cut[:, :MPG]
test_label = test_cut[:, :MPG]

# Get the list of columns to keep.
remove_names = filter(x->!in(x, [:MPG, :Model]), names(data))

# Filter the test and train sets.
train = Matrix(train_cut[:,remove_names]);
test = Matrix(test_cut[:,remove_names]);
````




## Model Specification

In a traditional frequentist model using [OLS](https://en.wikipedia.org/wiki/Ordinary_least_squares), our model might look like:

\$\$
MPG_i = \alpha + \boldsymbol{\beta}^T\boldsymbol{X_i}
\$\$

where $$\boldsymbol{\beta}$$ is a vector of coefficients and $$\boldsymbol{X}$$ is a vector of inputs for observation $$i$$. The Bayesian model we are more concerned with is the following:

\$\$
MPG_i \sim \mathcal{N}(\alpha + \boldsymbol{\beta}^T\boldsymbol{X_i}, \sigma^2)
\$\$

where $$\alpha$$ is an intercept term common to all observations, $$\boldsymbol{\beta}$$ is a coefficient vector, $$\boldsymbol{X_i}$$ is the observed data for car $$i$$, and $$\sigma^2$$ is a common variance term.

For $$\sigma^2$$, we assign a prior of `TruncatedNormal(0,100,0,Inf)`. This is consistent with [Andrew Gelman's recommendations](http://www.stat.columbia.edu/~gelman/research/published/taumain.pdf) on noninformative priors for variance. The intercept term ($$\alpha$$) is assumed to be normally distributed with a mean of zero and a variance of three. This represents our assumptions that miles per gallon can be explained mostly by our assorted variables, but a high variance term indicates our uncertainty about that. Each coefficient is assumed to be normally distributed with a mean of zero and a variance of 10. We do not know that our coefficients are different from zero, and we don't know which ones are likely to be the most important, so the variance term is quite high. The syntax `::Type{T}=Vector{Float64}` allows us to maintain type stability in our model -- for more information, please review the [performance tips](https://turing.ml/dev/docs/using-turing/performancetips#make-your-model-type-stable). Lastly, each observation $$y_i$$ is distributed according to the calculated `mu` term given by $$\alpha + \boldsymbol{\beta}^T\boldsymbol{X_i}$$.

````julia
# Bayesian linear regression.
@model linear_regression(x, y, n_obs, n_vars, ::Type{T}=Vector{Float64}) where {T} = begin
    # Set variance prior.
    σ₂ ~ truncated(Normal(0,100), 0, Inf)
    
    # Set intercept prior.
    intercept ~ Normal(0, 3)
    
    # Set the priors on our coefficients.
    coefficients = T(undef, n_vars)
    
    for i in 1:n_vars
        coefficients[i] ~ Normal(0, 10)
    end
    
    # Calculate all the mu terms.
    mu = intercept .+ x * coefficients
    y ~ MvNormal(mu, σ₂)
end;
````




With our model specified, we can call the sampler. We will use the No U-Turn Sampler ([NUTS](http://turing.ml/docs/library/#-turingnuts--type)) here. 

````julia
n_obs, n_vars = size(train)
model = linear_regression(train, train_label, n_obs, n_vars)
chain = sample(model, NUTS(0.65), 3000);
````




As a visual check to confirm that our coefficients have converged, we show the densities and trace plots for our parameters using the `plot` functionality.

````julia
plot(chain)
````


![](/tutorials/figures/5_LinearRegression_7_1.png)


It looks like each of our parameters has converged. We can check our numerical esimates using `describe(chain)`, as below.

````julia
describe(chain)
````


````
2-element Array{ChainDataFrame,1}

Summary Statistics
. Omitted printing of 2 columns
│ Row │ parameters       │ mean       │ std      │ naive_se   │ mcse       
│
│     │ Symbol           │ Float64    │ Float64  │ Float64    │ Float64    
│
├─────┼──────────────────┼────────────┼──────────┼────────────┼────────────
┤
│ 1   │ coefficients[1]  │ 0.407842   │ 0.463861 │ 0.0103723  │ 0.0132011  
│
│ 2   │ coefficients[2]  │ -0.130214  │ 0.469199 │ 0.0104916  │ 0.0131803  
│
│ 3   │ coefficients[3]  │ -0.0982566 │ 0.450733 │ 0.0100787  │ 0.0140963  
│
│ 4   │ coefficients[4]  │ 0.620113   │ 0.289531 │ 0.00647411 │ 0.0080144  
│
│ 5   │ coefficients[5]  │ 0.0278808  │ 0.439534 │ 0.00982827 │ 0.0126099  
│
│ 6   │ coefficients[6]  │ 0.0787792  │ 0.299914 │ 0.00670628 │ 0.00853917 
│
│ 7   │ coefficients[7]  │ -0.0765938 │ 0.280072 │ 0.0062626  │ 0.00682248 
│
│ 8   │ coefficients[8]  │ 0.131162   │ 0.262825 │ 0.00587694 │ 0.00751492 
│
│ 9   │ coefficients[9]  │ 0.282055   │ 0.454028 │ 0.0101524  │ 0.0100279  
│
│ 10  │ coefficients[10] │ -0.842593  │ 0.440175 │ 0.0098426  │ 0.0147895  
│
│ 11  │ intercept        │ 0.0511282  │ 0.182638 │ 0.0040839  │ 0.004774   
│
│ 12  │ σ₂               │ 0.465853   │ 0.11617  │ 0.00259765 │ 0.00488799 
│

Quantiles
. Omitted printing of 1 columns
│ Row │ parameters       │ 2.5%      │ 25.0%       │ 50.0%      │ 75.0%    
 │
│     │ Symbol           │ Float64   │ Float64     │ Float64    │ Float64  
 │
├─────┼──────────────────┼───────────┼─────────────┼────────────┼──────────
─┤
│ 1   │ coefficients[1]  │ -0.504624 │ 0.12914     │ 0.423049   │ 0.678483 
 │
│ 2   │ coefficients[2]  │ -1.06901  │ -0.423824   │ -0.132534  │ 0.153955 
 │
│ 3   │ coefficients[3]  │ -1.06518  │ -0.367724   │ -0.0824292 │ 0.182855 
 │
│ 4   │ coefficients[4]  │ 0.0454532 │ 0.434371    │ 0.620299   │ 0.795896 
 │
│ 5   │ coefficients[5]  │ -0.835723 │ -0.252707   │ 0.0243348  │ 0.316249 
 │
│ 6   │ coefficients[6]  │ -0.493104 │ -0.115398   │ 0.080025   │ 0.268767 
 │
│ 7   │ coefficients[7]  │ -0.651514 │ -0.257678   │ -0.0700555 │ 0.0954144
 │
│ 8   │ coefficients[8]  │ -0.369457 │ -0.0378038  │ 0.133924   │ 0.296483 
 │
│ 9   │ coefficients[9]  │ -0.592153 │ -0.00703827 │ 0.265888   │ 0.56584  
 │
│ 10  │ coefficients[10] │ -1.75055  │ -1.09835    │ -0.832778  │ -0.578763
 │
│ 11  │ intercept        │ -0.302891 │ -0.0650322  │ 0.0531147  │ 0.161785 
 │
│ 12  │ σ₂               │ 0.300119  │ 0.383562    │ 0.445753   │ 0.526997 
 │
````




## Comparing to OLS

A satisfactory test of our model is to evaluate how well it predicts. Importantly, we want to compare our model to existing tools like OLS. The code below uses the [GLM.jl]() package to generate a traditional OLS multivariate regression on the same data as our probabalistic model.

````julia
# Import the GLM package.
using GLM

# Perform multivariate OLS.
ols = lm(@formula(MPG ~ Cyl + Disp + HP + DRat + WT + QSec + VS + AM + Gear + Carb), train_cut)

# Store our predictions in the original dataframe.
train_cut.OLSPrediction = unstandardize(GLM.predict(ols), data.MPG);
test_cut.OLSPrediction = unstandardize(GLM.predict(ols, test_cut), data.MPG);
````




The function below accepts a chain and an input matrix and calculates predictions. We use the mean observation of each parameter in the model starting with sample 200, which is where the warm-up period for the NUTS sampler ended.

````julia
# Make a prediction given an input vector.
function prediction(chain, x)
    p = get_params(chain[200:end, :, :])
    α = mean(p.intercept)
    β = collect(mean.(p.coefficients))
    return  α .+ x * β
end
````


````
prediction (generic function with 1 method)
````




When we make predictions, we unstandardize them so they're more understandable. We also add them to the original dataframes so they can be placed in context.

````julia
# Calculate the predictions for the training and testing sets.
train_cut.BayesPredictions = unstandardize(prediction(chain, train), data.MPG);
test_cut.BayesPredictions = unstandardize(prediction(chain, test), data.MPG);

# Unstandardize the dependent variable.
train_cut.MPG = unstandardize(train_cut.MPG, data.MPG);
test_cut.MPG = unstandardize(test_cut.MPG, data.MPG);

# Show the first side rows of the modified dataframe.
first(test_cut, 6)
````


````
6×13 DataFrame. Omitted printing of 7 columns
│ Row │ MPG     │ Cyl      │ Disp      │ HP        │ DRat      │ WT       │
│     │ Float64 │ Float64  │ Float64   │ Float64   │ Float64   │ Float64  │
├─────┼─────────┼──────────┼───────────┼───────────┼───────────┼──────────┤
│ 1   │ 116.195 │ 1.01488  │ 0.591245  │ 0.0483133 │ -0.835198 │ 0.222544 │
│ 2   │ 114.295 │ 1.01488  │ 0.962396  │ 1.4339    │ 0.249566  │ 0.636461 │
│ 3   │ 120.195 │ 1.01488  │ 1.36582   │ 0.412942  │ -0.966118 │ 0.641571 │
│ 4   │ 128.295 │ -1.22486 │ -1.22417  │ -1.17684  │ 0.904164  │ -1.31048 │
│ 5   │ 126.995 │ -1.22486 │ -0.890939 │ -0.812211 │ 1.55876   │ -1.10097 │
│ 6   │ 131.395 │ -1.22486 │ -1.09427  │ -0.491337 │ 0.324377  │ -1.74177 │
````




Now let's evaluate the loss for each method, and each prediction set. We will use sum of squared error function to evaluate loss, given by 

\$\$
\text{SSE} = \sum{(y_i - \hat{y_i})^2}
\$\$

where $$y_i$$ is the actual value (true MPG) and $$\hat{y_i}$$ is the predicted value using either OLS or Bayesian linear regression. A lower SSE indicates a closer fit to the data.

````julia
bayes_loss1 = sum((train_cut.BayesPredictions - train_cut.MPG).^2)
ols_loss1 = sum((train_cut.OLSPrediction - train_cut.MPG).^2)

bayes_loss2 = sum((test_cut.BayesPredictions - test_cut.MPG).^2)
ols_loss2 = sum((test_cut.OLSPrediction - test_cut.MPG).^2)

println("Training set:
    Bayes loss: $$bayes_loss1
    OLS loss: $$ols_loss1
Test set: 
    Bayes loss: $$bayes_loss2
    OLS loss: $$ols_loss2")
````


````
Training set:
    Bayes loss: 67.58346459563484
    OLS loss: 67.56037474764642
Test set: 
    Bayes loss: 275.9392016063293
    OLS loss: 270.9481307076011
````




As we can see above, OLS and our Bayesian model fit our training set about the same. This is to be expected, given that it is our training set. But when we look at our test set, we see that the Bayesian linear regression model is better able to predict out of sample.
