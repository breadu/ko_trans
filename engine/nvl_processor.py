import numpy as np
from sklearn.cluster import DBSCAN

def get_nvl_paragraphs(candidates):
    """
    Groups individual text fragments into logical paragraphs using DBSCAN clustering.
    Specifically designed for NVL (Novel) mode where text blocks are distributed across the screen.

    Args:
        candidates: List of dictionaries, each containing a 'box' key [x, y, w, h].

    Returns:
        A list of paragraphs, where each paragraph is a list of spatially related text boxes.
    """
    if not candidates:
        return []

    # Map text fragments to 2D points using their geometric centers for spatial analysis
    points = []
    for c in candidates:
        x, y, w, h = c['box']
        points.append([x + w / 2, y + h / 2])

    points = np.array(points)

    # Perform Density-Based Spatial Clustering (DBSCAN) to identify related text blocks
    # eps (150): Maximum distance to group adjacent lines; may require tuning based on resolution.
    # min_samples (1): Ensures isolated lines are still captured as valid individual paragraphs.
    clustering = DBSCAN(eps=150, min_samples=1).fit(points)
    labels = clustering.labels_

    # Aggregate candidate boxes into groups based on their calculated cluster IDs
    groups = {}
    for i, label in enumerate(labels):
        if label not in groups:
            groups[label] = []
        groups[label].append(candidates[i])

    valid_paragraphs = []
    for label, group in groups.items():
        # Skip noise points identified by DBSCAN (-1)
        if label == -1:
            continue

        # Sort text boxes within each cluster: primarily by top-to-bottom, secondarily left-to-right
        group.sort(key=lambda b: (b['box'][1], b['box'][0]))
        valid_paragraphs.append(group)

    # Order the final list of paragraphs based on the vertical position of their first line
    valid_paragraphs.sort(key=lambda g: g[0]['box'][1])

    return valid_paragraphs