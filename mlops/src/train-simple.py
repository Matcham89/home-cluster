# src/train_simple.py
from sklearn.datasets import load_iris
from sklearn.model_selection import train_test_split
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import accuracy_score
import pickle

# Load the iris dataset (built into scikit-learn)
iris = load_iris()
X = iris.data  # Features: sepal length, width, petal length, width
y = iris.target  # Target: species (0, 1, or 2)

# Split data: 80% training, 20% testing
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)

# Train a Random Forest model
model = RandomForestClassifier(n_estimators=100, random_state=42)
model.fit(X_train, y_train)

# Evaluate
predictions = model.predict(X_test)
accuracy = accuracy_score(y_test, predictions)

print(f"Model Accuracy: {accuracy:.2%}")

# Save the model
with open('models/iris_model.pkl', 'wb') as f:
    pickle.dump(model, f)

print("Model saved to models/iris_model.pkl")
