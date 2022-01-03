#! /bin/bash

# Ce script implémente un serveur.
# Le script doit être invoqué avec l'argument :
# PORT   le port sur lequel le serveur attend ses clients

if [ $# -ne 1 ]; then
    echo "usage: $(basename $0) PORT"
    exit -1
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
        read -r cmd args || exit -1
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
    wc -l "$1" | egrep -o '[0-9]+' | head -n 1
}

function parseHeader () {
    local archiveFile="$1"
    local line
    read line < "$archiveFile"
    local beginHeader=$(echo $line | cut -d: -f1)
    local beginBody=$(echo $line | cut -d: -f2)
    head -n $((beginBody-1)) "$archiveFile" | tail -n $((beginBody-beginHeader-1))
}

function parseBody () {
    local archiveFile="$1"
    local line
    read line < "$archiveFile"
    local beginBody=$(echo $line | cut -d: -f2)
    tail -n $(($(wcl "$archiveFile")-beginBody)) "$archiveFile"
}

function listInDirectory () {
    local archiveFile="$1"
    local currentDir="$2"
    parseHeader $archiveFile | awk "
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
    destDir=$(echo "$destDir" | sed -r 's/\\+/\\/g')
    ## On remplace les \\.. par \\;
    while [[ $(echo "$destDir" | egrep '\\\.\.(\\.*)?$') ]]
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
    find . -name "*.archive.txt" -maxdepth 1 -exec echo "{}" >> find.txt \;
    local length=$(wcl find.txt)
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


    #Deux fichiers qu'on va concaténer à la fin
    touch header.txt
    touch body.txt

    #On laisse une ligne en haut pour noter le début du header et du body
    echo -e "\n" >> header.txt
    curseur_body=0

    # On recherche tous les dossiers de l'arborescence pour lister leur contenu
    find "$dossier" -type d | while read absolute
    do
        relative=$(printf "%s" $absolute | sed s:^$dossier::)
        [[ "$relative" == '' ]] && relative="\\" # For root directory
        echo "directory $relative\\" >> header.txt
        # On boucle sur le contenu du dossier pour afficher les informations de chaque fichier/dossier
        ls -l "$absolute" | sed /^total/d | while read rights _ _ _ size _ _ _ name
        do
            export toprint="$name $rights"
            if [[ "$size" != "0" ]]
            then
                export toprint="$toprint $size"
                if [[ -f "$absolute/$name" ]]
                then
                    export toprint="$toprint $((($(wcl body.txt)+1))) $(wcl $absolute/$name)"
                    cat "$absolute/$name" >> body.txt
                fi
            fi
            echo $toprint
        done >> header.txt
        echo "@" >> header.txt
    done

    #On cherche les directory
    # for i in $(ls)
    # do
    #   if [ -d $i ]; then
    #     ((d++))
    #     #Mettre le nom du dossier dans le fichiers
    #     echo -e "directory $(ls)\n" >> header.txt
    #     nb_lignes=$(wc -l $(ls))
    #     #Ecrire ce qu'il y a dans le fichier dans l'archive
    #     #cat body.txt ($(ls)).txt > body.txt
    #     taille=$(ls -l $i | cut -d' ' -f5)
    #     echo -e "\n\n" >> body.txt
    #     #Mettre les dossiers et fichiers en-dessous avec nom, droit, poids et début et fin
    #     echo -e "$(ls -a) $(ls -l) $taille $curseur_body (($curseur_body+$nb_lignes))" >> header.txt
    #     (($nb_lignes+=1))
    #     (($curseur_body+=$nb_lignes))
    #   fi
    #   #Mettre un @ pour dire qu'on change de dossier
    #   echo -e "@\n" >> header.txt
    # done

    taille_header=$(wcl header.txt)
    #Ajouter au début du fichier header
    # sed -i 1s/.*/`((taille_header+2))`\n/g "header.txt"
    echo "3:$(((taille_header+2)))" | cat - header.txt > temp 
    mv temp header.txt

    #Concaténer header et body
    sed -i '' 's/\//\\/g' header.txt
    cat header.txt body.txt > $nom.archive.txt
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
    #2
    #3
    archive=$2
    currentDir=$3
    archiveFile="./$archive.archive.txt"
    local currentDir=$(echo "$currentDir" | sed -r 's/^(.*[^\\]+)\\*$/\1\\/')
    local list=$(listInDirectory "$archiveFile" "$currentDir")
    local length=$(echo "$list" | wc -l | egrep -o [0-9]+)
    if [[  $length -eq 0 ]]
    then
        echo "1
        Le dossier est vide $length"
    else
        echo $length
        echo "$list" | sed -r 's/(^.*) ([dlrwx-]+) ([0-9]*)( [0-9]+ [0-9]+)?$/\2 \1 \3/g'
    fi
}

function commande-browse-cd () {
    archive=$2
    currentDir=$3
    destDir=$4
    archiveFile="./$archive.archive.txt"

    # ici, il faut renvoyer le chemin absolu du nouveau répertoire de travail avec des / comme séparateur de dossier
    # chemin absolu = chemin relatif à la racine de l'archive
    local destDir=$(formatAbsolutePath "$currentDir" "$destDir")
    if [[ $? -eq 1 ]]
    then
        echo "1
        Erreur : vous essayez de remonter au delà de la racine \\"
        exit 0
    fi
    if [[ "$destDir" != "\\" ]]
    then
        local parentDir=$(echo "$destDir" | sed -r 's/^(.*\\)[^\\]+(\\)?$/\1/g')
        local lastDir=$(echo "$destDir" | sed -r 's/\\([^\\]+)(\\)?$/\1/g')
        local list=$(listInDirectory "$archiveFile" "$parentDir")
        if [[ ! $(echo "$list" | egrep "^$lastDir d") ]]
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
    local files
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
        local parentDir=$(echo "$file" | sed -r 's/^(.*\\)[^\\]+(\\)*$/\1/g' | sed -r 's/\\+/\\/g')
        local onlyFile=$(echo "$file" | sed -r 's/^.*\\([^\\]+)(\\)*$/\1/g')
        local list=$(listInDirectory "$archiveFile" "$parentDir")
        local line=$(echo "$list" | egrep "^$onlyFile -")
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
        read name rights size begin lines <<< $info
        [[ -n "$lines" ]] && ((totalLines+=lines))
    done
    echo $totalLines

    # On affiche les fichiers
    for ((i = 0 ; i < $fileNumber ; i++))
    do
        read name rights size begin lines <<< ${infoFilesArr[$i]}
        if [[ -n "$size" ]]
        then
            local body=$(parseBody "$archiveFile")
            echo "$body" | head -n $((begin+lines-1)) | tail -n $lines
        fi
    done
}

function commande-browse-rm () {
    local archive=$2
    local currentDir=$3
    local archiveFile="./$archive.archive.txt"
    local files
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
        local parentDir=$(echo "$file" | sed -r 's/^(.*\\)[^\\]+(\\)*$/\1/g' | sed -r 's/\\+/\\/g')
        local onlyFile=$(echo "$file" | sed -r 's/^.*\\([^\\]+)(\\)*$/\1/g')
        local list=$(listInDirectory "$archiveFile" "$parentDir")

        local info=$(echo "$list" | egrep "^$onlyFile [dl-]")
        
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
        local archiveFile="$1"
        local file="$2"
        local info="$3"
        local name right size begin lines
        local parentDir=$(echo "$file" | sed -r 's/^(.*\\)[^\\]+(\\)*$/\1/g' | sed -r 's/\\+/\\/g')
        local onlyFile=$(echo "$file" | sed -r 's/^.*\\([^\\]+)(\\)*$/\1/g')
        local line

        # Retire la ligne du header
        local newContentArchive
        newContentArchive=$(awk "
            BEGIN {state=0; toprint=1}
            state==1 {state=2}
            state==0 && /^directory $(echo "$parentDir" | sed -r s/\\\\/\\\\\\\\/g)$/ {state=1}
            state==2 && /^@$/ {state=3}
            state==2 && /^$onlyFile [dlrwx-]+( [0-9]*)*$/ {toprint=0}
            toprint==1 {print}
            toprint==0 {toprint=1}
            " "$archiveFile")
        
        # Met à jour le début du body
        read line <<< "$newContentArchive"
        local beginHeader=$(echo $line | cut -d: -f1)
        local beginBody=$(echo $line | cut -d: -f2)
        ((beginBody--))
        newContentArchive=$(echo "$newContentArchive" | sed -r "s/:.*/:$beginBody/g")
        read name rights size begin lines <<< $info
        if [[ -n "$lines" ]]
        then
            # Retire le contenu du fichier du body
            # Met à jour les débuts de fichiers dans le header
            echo "$newContentArchive" | awk "
                NR < $beginHeader {print}
                NR >= $beginHeader && NR < $beginBody {
                    if(\$4 > $begin) \$4-=$lines; 
                    print
                }
                NR >= $beginBody && (NR < $beginBody+$begin || NR > $beginBody+$begin+$lines-1) {print}" > "$archiveFile"
        fi
    }
    function deleteDir () {
        local archiveFile="$1"
        local dir=$(echo "$2" | sed -r 's/(^.*[^\\])\\*$/\1\\/g')
        local info="$3"
        local list=$(listInDirectory "$archiveFile" "$dir")
        echo "dir: $dir, list: $list"
        local onlyDir=$(echo "$file" | sed -r 's/^.*\\([^\\]+)(\\)*$/\1/g')
        local line
        read line < "$archiveFile"
        local beginHeader=$(echo $line | cut -d: -f1)
        local beginBody=$(echo $line | cut -d: -f2)
        local name
        while read line 
        # On supprime le contenu du dossier
        do
            read name _ <<< "$line"
            echo "line: $line"
            echo "$dir > $name"
            # if [[ "$right" =~ ^d ]]
            # then # directory
            #     deleteDir "$archiveFile" "$item" "$info"
            # else # fichier
            #     deleteFile "$archiveFile" "$item" "$info"
            # fi
            deleteItem "$archiveFile" "$dir$name" "$line"
        done <<< "$list"

        # On supprime le dossier en lui même
        local newContentArchive=$(cat "$archiveFile")
        echo "$newContentArchive" | awk "
            BEGIN {toprint=0}
            toprint!=0 {toprint--}
            NR < $beginHeader {print}
            NR >= $beginHeader && NR < $beginBody && toprint==0 {print}
            NR >= $beginHeader && NR < $beginBody && /^directory $onlyDir$/ {toprint=2}
            NR >= $beginBody {print}" > "$archiveFile"



    }
    function deleteItem () {
        local archiveFile="$1"
        local item="$2"
        local info="$3"
        local name right size begin lines
        read name rights size begin lines <<< $info
        if [[ "$rights" =~ ^d ]]
        then # directory
            echo "deleting $item as dir"
            deleteDir "$archiveFile" "$item" "$info"
        else # fichier
            echo "deleting $item as file"
            deleteFile "$archiveFile" "$item" "$info"
        fi
        # echo "1
        # Les suppressions ont été effectuées."
    }

    # On affiche les fichiers
    for ((i = 0 ; i < $fileNumber ; i++))
    do
        deleteItem "$archiveFile" "${absoluteFilesArr[$i]}" "${infoFilesArr[$i]}"
    done
    echo "DEBUGEND"
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
    echo $(wcl "$fichier")
    cat "$fichier"
}


# On accepte et traite les connexions

accept-loop
