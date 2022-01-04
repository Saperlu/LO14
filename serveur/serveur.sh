#! /usr/local/bin/bash

# Ce script implémente un serveur.
# Le script doit être invoqué avec l'argument :
# PORT   le port sur lequel le serveur attend ses clients

if [ $# -ne 1 ]; then
    echo "usage: $(basename $0) PORT"
    exit 0
fi

PORT="$1"

# Déclaration du tube

FIFO="/tmp/$USER-fifo-$$-serveur"
logger="/tmp/$USER-f-$$-serveur"


# Il faut détruire le tube quand le serveur termine pour éviter de
# polluer /tmp.  On utilise pour cela une instruction trap pour être sur de
# nettoyer même si le serveur est interrompu par un signal.

function nettoyage() { rm -f "$FIFO" "$logger"; }
trap nettoyage EXIT

# on crée le tube nommé

[ -e "$FIFO" ] || mkfifo "$FIFO"
[ -e "$logger" ] || mkfifo "$logger"


function accept-loop() {
    while true; do
    interaction < "$FIFO" | netcat -l -p "$PORT" > "$FIFO" 2>/dev/null
    cat "$logger" | cut -c1-60
    done
}

# La fonction interaction lit les commandes du client sur entrée standard
# et envoie les réponses sur sa sortie standard.
#
# 	CMD arg1 arg2 ... argn
#
# alors elle invoque la fonction :
#
#         commande-CMD arg1 arg2 ... argn
#
# si elle existe; sinon elle envoie une réponse d'erreur.

function interaction() {
    local cmd args
    while true; do
        read -r cmd args || exit 0
        echo "$cmd $args" > "$logger" &
        fun="commande-$cmd"
        if [ "$(type -t $fun)" = "function" ]; then
            $fun $args
        else
            commande-non-comprise $fun $args
        fi
    done
}

# Les fonctions implémentant les différentes commandes du serveur

function wcl () {
    wc -l "$1" | grep -E -o '[0-9]+' | head -n 1
}

function parseHeader () {
    local archiveFile="$1"
    local line
    read -r line < "$archiveFile"
    local beginHeader
    beginHeader=$(echo "$line" | cut -d: -f1)
    local beginBody
    beginBody=$(echo "$line" | cut -d: -f2)
    head -n $((beginBody-1)) "$archiveFile" | tail -n $((beginBody-beginHeader-1))
}

function parseBody () {
    local archiveFile="$1"
    local line
    read -r line < "$archiveFile"
    local beginBody
    beginBody=$(echo "$line" | cut -d: -f2)
    tail -n $(($(wcl "$archiveFile")-beginBody)) "$archiveFile"
}

function listInDirectory () {
    local archiveFile="$1"
    local currentDir="$2"
    parseHeader "$archiveFile" | awk "
    BEGIN {state=0}
    state==1 {state=2}
    /^directory $(echo "$currentDir" | sed -r s/\\\\/\\\\\\\\/g)$/ {state=1}
    state==2 && /^@$/ {state=3}
    state==2 {print}"
}

function formatAbsolutePath () {
    local currentDir="$1"
    local destDir="$2"

    # Formatage du destDir
    if [[ ! "$destDir" =~ ^\\ ]]
    then # Conversion de relatif vers absolu
        destDir=$(printf %s\\%s "$currentDir" "$destDir")
    fi
    destDir=$(echo "$destDir" | \
        sed -r 's/\\+/\\/g' | \
        sed -r 's/^\.\\/\\/g' | \
        sed -r 's/\\\.\\/\\/g' | \
        sed -r 's/\\\.$/\\/g' \
    )
    ## On remplace les \\.. par \\;
    while [[ $(echo "$destDir" | grep -E '\\\.\.(\\.*)?$') ]]
    do
        destDir=$(echo "$destDir" | sed -r 's/\\\.\.(\\.*)?$/\\;\1/g')
    done
    while [[ "$destDir" =~ \; ]]
    do
        destDir=$(echo "$destDir" | sed -r 's/\\[^\\;]+\\;/\\/')
        destDir=$(echo "$destDir" | sed -r 's/\\+/\\/g')
        if [[ "$destDir" =~ ^\\\; ]]
        then
            return 1 # Erreur
        fi
    done
    echo "$destDir"
    return 0
}

function commande-non-comprise () {
    echo "Le serveur ne peut pas interpréter cette commande"
}

function commande-echo () {
    if [ $1 == "bonjour" ]
    then
        echo "bonjour, je suis à votre service"
    fi
}

function commande-list () {
    # Le nombre d'archives suivi des noms des archives
    # Récupérer les noms différentes archives
    find . -name "*.archive.txt" -maxdepth 1 -exec echo "{}" >> "find.txt" \;
    local length
    length=$(wcl find.txt)
    echo "$(((length+1)))"
    echo "Il y a $length archives."
    sed "s:./\(.*\).archive.txt$:\1:g" find.txt
    rm find.txt
}

function commande-create () {
    nom=$1
    archive=$2
    dossier="/tmp/dossier-$USER-$$-$nom"
    mkdir "$dossier"
    echo $archive | base64 -d | tar -xz -C "$dossier"
    # Tout se trouve dans le dossier $dossier
    local toprint

    #Deux fichiers qu'on va concaténer à la fin
    touch header.txt
    touch body.txt

    #On laisse une ligne en haut pour noter le début du header et du body
    echo -e "\n" >> header.txt

    # On recherche tous les dossiers de l'arborescence pour lister leur contenu
    find "$dossier" -type d | while read -r absolute
    do
        relative=$(printf "%s" "$absolute" | sed "s:^$dossier::")
        [[ "$relative" == '' ]] && relative="\\" # For root directory
        echo "directory $relative\\" >> "header.txt"
        # On boucle sur le contenu du dossier pour afficher les informations de chaque fichier/dossier
        ls -l "$absolute" | sed /^total/d | while read -r rights _ _ _ size _ _ _ name
        do
            toprint="$name $rights"
            if [[ "$size" != "0" ]]
            then
                toprint="$toprint $size"
                if [[ -f "$absolute/$name" ]]
                then
                    toprint="$toprint $((($(wcl body.txt)+1))) $(wcl $absolute/$name)"
                    cat "$absolute/$name" >> body.txt
                fi
            fi
            echo "$toprint"
        done >> header.txt
        echo "@" >> header.txt
    done

    taille_header=$(wcl header.txt)
    #Ajouter au début du fichier header
    echo "3:$(((taille_header+2)))" | cat - header.txt > temp 
    mv temp header.txt

    #Concaténer header et body
    sed -i '' 's/\//\\/g' header.txt
    cat header.txt body.txt > "$nom.archive.txt"
    rm body.txt
    rm header.txt


    rm -rf "$dossier"
    echo "1
            L'archive $nom a bien été créée"
}

function commande-browse () {
    if [ "$(type -t $fun-$1)" = "function" ]; then
        archiveFile="./$2.archive.txt"
        if [[ -e "$archiveFile" ]]
        then
            $fun-$1 $args
        else
            echo "1
            Erreur : l'archive n'existe pas"
            exit 0
        fi
    else
        commande-non-comprise $fun $args
    fi
}

function commande-browse-ls () {
    # Arguments
    local archive currentDir destDir options
    archive="$2"
    currentDir="$3"
    destDir="$4"
    options="$5"
    local list archiveFile name right

    archiveFile="./$archive.archive.txt"
    currentDir=$(formatAbsolutePath "$currentDir" "$destDir" | sed -r 's/^(.*[^\\]+)\\*$/\1\\/')
    list=$(listInDirectory "$archiveFile" "$currentDir")

    if [[ ! "$options" =~ "a" ]]
    then
        list=$(echo "$list" | sed -r '/^\./d')
    fi
    local length
    length=$(echo "$list" | wc -l | grep -E -o "[0-9]+")
    if [[ "$options" =~ "l" ]]
    then
        echo "$length"
        echo "$list" | sed -r -e 's/(^.*) ([dlrwx-]+) ([0-9]*)( [0-9]+ [0-9]+)?$/\2 \1 \3/g'  -e 's/(^.*) ([dlrwx-]+)$/\2 \1/g'
    else
        echo "1"
        echo "$list" | while read -r line
        do
            read -r name right _ <<< $line
            printf "%s" "$name"
            if [[ "$right" =~ ^d ]]
            then 
                printf "\\"
            elif [[ "$right" =~ ^...x ]]
            then
                printf "*"
            fi
            printf " "
        done
        printf "\n"
    fi


}

function commande-browse-cd () {
    local archive currentDir destDir
    archive=$2
    currentDir=$3
    destDir=$4
    local archiveFile
    archiveFile="./$archive.archive.txt"

    # ici, il faut renvoyer le chemin absolu du nouveau répertoire de travail avec des / comme séparateur de dossier
    # chemin absolu = chemin relatif à la racine de l'archive
    destDir=$(formatAbsolutePath "$currentDir" "$destDir")
    if [[ $? -eq 1 ]]
    then
        echo "1
        Erreur : vous essayez de remonter au delà de la racine \\"
        exit 0
    fi
    if [[ "$destDir" != "\\" ]]
    then
        local parentDir
        parentDir=$(echo "$destDir" | sed -r 's/^(.*\\)[^\\]+(\\)?$/\1/g')
        local lastDir
        lastDir=$(echo "$destDir" | sed -r 's/\\([^\\]+)(\\)?$/\1/g')
        local list
        list=$(listInDirectory "$archiveFile" "$parentDir")
        if [[ ! $(echo "$list" | grep -E "^$lastDir d") ]]
        then
            echo "1
            Erreur : le dossier n'existe pas."
        fi
    fi
    echo "1
    $destDir"
    
}

function commande-browse-cat () {
    #1
    archive=$2
    currentDir=$3
    archiveFile="./$archive.archive.txt"
    local absoluteFilesArr=()
    local infoFilesArr=()
    local fileNumber=0
    # On vérifie que les fichiers ne remontent pas au dessus de \ et on remplie les tableaux absoluteFilesArr et infoFilesArr
    while [[ -n "$4" ]]
    do
        ((fileNumber++))
        local file=$4
        file=$(formatAbsolutePath "$currentDir" "$file")
        if [[ $? -eq 1 ]]
        then
            echo "1
            Erreur : vous essayez de remonter au delà de la racine \\ >> $4"
            exit 0
        fi
        absoluteFilesArr+=("$file")
        local parentDir
        parentDir=$(echo "$file" | sed -r 's/^(.*\\)[^\\]+(\\)*$/\1/g' | sed -r 's/\\+/\\/g')
        local onlyFile
        onlyFile=$(echo "$file" | sed -r 's/^.*\\([^\\]+)(\\)*$/\1/g')
        local list
        list=$(listInDirectory "$archiveFile" "$parentDir")
        local line
        line=$(echo "$list" | grep -E "^$onlyFile -")
        infoFilesArr+=("$line")
        shift
    done

    # On compte le nombre de lignes total et on vérifie que tous les fichiers existent
    local i
    local totalLines=0
    for ((i = 0 ; i < $fileNumber ; i++))
    do
        local info="${infoFilesArr[$i]}"
        if [[ -z "$info" ]]
        then
            echo "1
            Erreur : le fichier < ${absoluteFilesArr[$i]} > n'existe pas."
            exit 0
        fi
        read -r name rights size begin lines <<< $info
        [[ -n "$lines" ]] && ((totalLines+=lines))
    done
    echo $totalLines

    # On affiche les fichiers
    for ((i = 0 ; i < $fileNumber ; i++))
    do
        read -r name rights size begin lines <<< ${infoFilesArr[$i]}
        if [[ -n "$size" ]]
        then
            local body
            body=$(parseBody "$archiveFile")
            echo "$body" | head -n $((begin+lines-1)) | tail -n $lines
        fi
    done
}

function commande-browse-rm () {
    local archive=$2
    local currentDir=$3
    local archiveFile="./$archive.archive.txt"
    local absoluteFilesArr=()
    local infoFilesArr=()
    local fileNumber=0
    # On vérifie que les fichiers ne remontent pas au dessus de \ 
    # et on remplie les tableaux absoluteFilesArr et infoFilesArr
    # et on vérifie que tous les fichiers existent
    while [[ -n "$4" ]]
    do
        ((fileNumber++))
        local file=$4
        file=$(formatAbsolutePath "$currentDir" "$file")

        # On vérifie que les fichiers ne remontent pas au dessus de \ 
        if [[ $? -eq 1 ]]
        then
            echo "1
            Erreur : vous essayez de remonter au delà de la racine \\ >> $4"
            exit 0
        fi

        absoluteFilesArr+=("$file")
        local parentDir
        parentDir=$(echo "$file" | sed -r 's/^(.*\\)[^\\]+(\\)*$/\1/g' | sed -r 's/\\+/\\/g')
        local onlyFile
        onlyFile=$(echo "$file" | sed -r 's/^.*\\([^\\]+)(\\)*$/\1/g')
        local list
        list=$(listInDirectory "$archiveFile" "$parentDir")

        local info
        info=$(echo "$list" | grep -E "^$onlyFile [dl-]")
        
        # On vérifie que tous les fichiers existent
        if [[ -z "$info" ]]
        then
            echo "
            Erreur : le fichier ou le dossier < ${absoluteFilesArr[$i]} > n'existe pas."
            exit 0
        fi

        infoFilesArr+=("$info")
        shift
    done

    function deleteFile () {
        if [[ $# != 3 ]]
        then
            exit 0
        fi
        local archiveFile="$1"
        local file="$2"
        local info="$3"
        local parentDir
        parentDir=$(echo "$file" | sed -r 's/^(.*\\)[^\\]+(\\)*$/\1/g' | sed -r 's/\\+/\\/g')
        local onlyFile
        onlyFile=$(echo "$file" | sed -r 's/^.*\\([^\\]+)(\\)*$/\1/g')
        local line

        # Retire la ligne du header
        local newContentArchive
        newContentArchive=$(awk "
            BEGIN {state=0; toprint=1}
            state==1 {state=2}
            state==0 && /^directory $(echo "$parentDir" | sed -r s/\\\\/\\\\\\\\/g)$/ {state=1}
            state==2 && /^@$/ {state=3}
            state==2 && /^$onlyFile [dlrwx-]{10}.*$/ {toprint=0}
            toprint==1 {print}
            toprint==0 {toprint=1}
            " "$archiveFile")
        
        # Met à jour le début du body
        read -r line <<< "$newContentArchive"
        local beginHeader
        beginHeader=$(echo "$line" | cut -d: -f1)
        local beginBody
        beginBody=$(echo "$line" | cut -d: -f2)
        ((beginBody--))
        newContentArchive=$(echo "$newContentArchive" | sed -r "s/:.*/:$beginBody/1")
        local name right size begin lines
        read -r name rights size begin lines <<< "$info"
        if [[ -n "$lines" ]]
        then
            # Retire le contenu du fichier du body
            # Met à jour les débuts de fichiers dans le header
            newContentArchive=$(echo "$newContentArchive" | awk "
                NR < $beginHeader {print}
                NR >= $beginHeader && NR < $beginBody {
                    if(\$4 > $begin) \$4-=$lines; 
                    print
                }
                NR >= $beginBody && (NR < $beginBody+$begin || NR > $beginBody+$begin+$lines-1) {print}")
        fi
        echo "$newContentArchive" > "$archiveFile"
    }
    function deleteDir () {
        local archiveFile="$1"
        local dir
        dir=$(echo "$2" | sed -r 's/(^.*[^\\])\\*$/\1\\/g')
        local info="$3"
        local list
        list=$(listInDirectory "$archiveFile" "$dir")
        local line
        read -r line < "$archiveFile"
        local name
        unset line; local line
        echo "$list" | while read -r line 
        # On supprime le contenu du dossier
        do
            read -r name _ <<< "$line"
            [[ -n "$name" ]] && deleteItem "$archiveFile" "$dir$name" "$line"
        done

        # On supprime le dossier en lui même
        local newContentArchive
        newContentArchive=$(cat "$archiveFile")
        # On met le beginBody à jour
        read -r line < "$archiveFile"
        local beginBody
        beginBody=$(echo "$line" | cut -d: -f2)
        ((beginBody-=2))
        newContentArchive=$(echo "$newContentArchive" | sed -r "s/:.*/:$beginBody/1")
        #On supprime le dossier du header
        echo "$newContentArchive" | sed "/^directory ${dir//\\/\\\\}$/,+1d" > "$archiveFile"
        # On supprime le dossier du dossier parent
        deleteFile "$archiveFile" "$dir" "$info"

    }
    function deleteItem () {
        local archiveFile="$1"
        local item="$2"
        local info="$3"
        local name right size begin lines
        read -r name right size begin lines <<< "$info"
        if [[ "$right" =~ ^d ]]
        then # directory
            deleteDir "$archiveFile" "$item" "$info"
        else # fichier
            deleteFile "$archiveFile" "$item" "$info"
        fi
    }

    # On affiche les fichiers
    for ((i = 0 ; i < "$fileNumber" ; i++))
    do
        deleteItem "$archiveFile" "${absoluteFilesArr[$i]}" "${infoFilesArr[$i]}"
    done
    echo "1
    Les suppressions ont été effectuées."
}

function commande-browse-touch () {
    archive=$2
    currentDir=$3
    fichier=$4
    echo "1
            $2> $3 $4"
}

function commande-browse-mkdir () {
    archive=$2
    currentDir=$3
    dossier=$4
    echo "1
            $2> $3 $4"
}

function commande-extract () {
    archive=$1
    fichier="./$1.archive.txt"
    if [[ ! -e "$fichier" ]]
    then
        echo "1
        Erreur : l'archive n'existe pas"
        exit 0
    fi
    wcl "$fichier"
    cat "$fichier"
}


# On accepte et traite les connexions

accept-loop
