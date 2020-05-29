#! /bin/bash
if [ ! -d "./env" ]; then
    echo "Virtual environment doesn't exist, creating one"
    
    # Install virtualenv 
    python3 -m pip install --user virtualenv

    #  Create a new environment
    python3 -m venv env

    # Activate the environment
    source env/bin/activate

    # Install needed packages
    pip install jupyter
    pip install jupyter_contrib_nbextensions
fi

# check to see if the markdown directory exists
if [ ! -d "./markdown" ]; then
    mkdir markdown
fi

# Activate the environment
source env/bin/activate

for filename in *.ipynb; do
    
    if [ "$(uname)" == "Darwin" ]; then
        ipyAge=$(stat -f %Y -- "$filename")
    elif [ "$(expr substr $(uname -s) 1 5)" == "Linux" ]; then
        ipyAge=$(stat -c %Y -- "$filename")
    fi
    outPath="markdown/${filename/.ipynb/.md}"

    
    if [ -f $outPath ]; then
        if [ "$(uname)" == "Darwin" ]; then
            mdAge=$(stat -f %Y -- $outPath)
        elif [ "$(expr substr $(uname -s) 1 5)" == "Linux" ]; then
            mdAge=$(stat -c %Y -- $outPath)
        fi
        mdExists=0
    else
        mdAge=0
        mdExists=0
    fi

    #if [ $mdExists -ne 0 ] || (( $ipyAge > $mdAge )); then
    if [ $mdExists -ne 0 ] || $( $ipyAge > $mdAge ); then
        echo "$filename needs to be reconverted as it has been updated."

        # Update the notebook itself by executing everything.
        env/bin/jupyter-nbconvert "$filename" --to notebook --inplace --ExecutePreprocessor.kernel_name="julia-1.4" --execute --ExecutePreprocessor.timeout=-1 --ExecutePreprocessor.startup_timeout=120

        # Capture the exit code.
        retVal=$?

        # Check if we ran the notebook without issues.
        if [ $retVal -ne 0 ]; then
            # We had an error code -- terminate early.
            # Note: Remove this line if you want to run all the notebooks and ignore
            #       any errors that might appear.
            echo "Error converting $filename"

            # Return the error code we got.
            # exit $retVal
        else
            # No errors happened, so we can convert the notebook to markdown.
            echo "Converting $filename to $outPath"
            env/bin/jupyter-nbconvert "$filename" --to markdown --output-dir="markdown"

            echo "Adding YAML headers to $outpath"
            julia -e "include(\"weave-examples.jl\"); handle_file(\"$outPath\")"
        fi
    fi
done

# exit 0